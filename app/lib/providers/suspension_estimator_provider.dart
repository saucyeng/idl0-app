import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../src/rust/session.dart' as rust;
import '../ui/tabs/analyze/chart_tile_cache.dart';
import 'channel_provider.dart';

/// Channel ids the offline suspension estimator stores into the session handle.
///
/// These strings are load-bearing: they must match **both** the Rust bridge's
/// `add_channel` ids (in `estimate_suspension_into_store`) **and** the builtin
/// math-channel names ([kBuiltinMathChannels]), because the chart decimates a
/// math channel by its name. Don't rename them in isolation.
const String kEstFrontTravelChannel = 'Front travel (mm)';
const String kEstFrontVelocityChannel = 'Front velocity (mm/s)';
const String kEstRearTravelChannel = 'Rear travel (mm)';
const String kEstRearVelocityChannel = 'Rear velocity (mm/s)';

/// The estimator's output channels — the set [mathChannelEvalProvider] routes to
/// the estimator instead of the expression evaluator.
const Set<String> kSuspensionEstimatorChannels = {
  kEstFrontTravelChannel,
  kEstFrontVelocityChannel,
  kEstRearTravelChannel,
  kEstRearVelocityChannel,
};

/// Hot-reload tuning surface for the offline suspension estimator.
///
/// These mirror the engine's reference defaults (`EstimatorConfig::default` +
/// `ProcessNoiseConfig::reference_default` + `InitStd::default`). The per-session
/// geometry store is deferred, so geometry stays the engine reference bike (which
/// carries flat-ground-calibrated unsprung mounts; per-session tilt refitting is
/// the opt-in `refineMounts`) and only these filter knobs are app-tunable.
/// **Edit the values here and hot-restart** to retune the loops (a hot reload
/// alone won't re-run the cached estimate — see [suspensionEstimatorProvider]).
rust.SuspensionConfig _defaultSuspensionConfig() => const rust.SuspensionConfig(
      estimateSteering: false,
      iekfIters: 1,
      // Stationary detector.
      zuptWindow: 20,
      zuptAccelStd: 0.1,
      zuptGyroThresh: 0.05,
      // Measurement-factor sigmas.
      zuptSigma: 0.02,
      zaruSigma: 1.0e-3,
      gravitySigma: 0.05,
      // GPS velocity aiding: sigma models the module's own smoothed output (its
      // internal filter correlates errors over seconds and lags the bike), not raw
      // noise — hence loose. Latency: a fix at t describes the bike at t − latency;
      // tune against hard-braking events. Min speed: course is noise below walking
      // pace (ZUPT covers stationary).
      gpsSigma: 0.5,
      gpsLatencyS: 0.2,
      gpsMinSpeedMps: 0.5,
      // Mounts are flat-ground-calibrated in the engine geometry; per-session
      // refitting (parked lean / flopped bars become mount error) stays off.
      refineMounts: false,
      // RTS backward pass over the wheel chains: each topout/stop anchor corrects
      // the interval BEFORE it (offline hindsight), not just forward. Turn off to
      // see the raw causal filter.
      smooth: true,
      // Sag-prior strength — INERT here: the estimator runs **bounds-only** by default
      // (the bridge hardcodes `use_sag_prior = false`; see `EstimatorConfig::use_sag_prior`).
      // Travel DC is anchored by the airborne topout reference and the [0, max] barrier,
      // not a sag pull, so the recovered velocity band stays undistorted. This value is
      // only honoured if the sag prior is re-enabled engine-side (an A/B toggle, not an
      // app surface today). Kept for that path.
      sagSigma: 0.5,
      barrierSigma: 0.005,
      // Lowered (was 4.0 m/s²): only deeper unweighting counts as free-fall, so
      // shallow rebound crests don't trip the topout zeroing. The sustained-
      // free-fall gate in the engine handles instantaneous deep dips.
      airborneAccelThresh: 2.5,
      // Relative free-fall veto (m/s²): airborne also requires every unsprung IMU's
      // lever-compensated diff-accel below this — a terrain-driven wheel has a large
      // diff-accel even when the chassis is momentarily light, so rough ground no
      // longer snaps travel to topout. Hot-reload knob: lower (stricter) if rough
      // ground still zeroes, higher (looser) if real floats get rejected mid-air.
      airborneDiffThresh: 5.0,
      topoutSigma: 0.01,
      // Process-noise PSDs.
      gyroArw: 0.003,
      accelVrw: 0.05,
      gyroBiasRw: 1.0e-4,
      accelBiasRw: 1.0e-3,
      gyro1BiasRw: 1.0e-4,
      gyro2BiasRw: 1.0e-4,
      wheelVelRw: 5.0,
      wheelPosRw: 1.0e-3,
      steerRateRw: 1.0,
      // Initial-covariance 1-σ priors.
      initAttitude: 0.08726646259971647, // 5°
      initVelocity: 1.0,
      initGyroBias: 0.05,
      initAccelBias: 0.5,
      initWheelTravel: 0.05,
      initWheelVelocity: 1.0,
      initSteerAngle: 0.2,
      initSteerRate: 1.0,
    );

/// Runs the offline suspension-kinematics estimator for [sessionId] **once**, and
/// caches the result. The Rust engine stores all four outputs (front/rear travel
/// in mm + velocity in mm/s) into the session handle's math store; the returned
/// metadata carries their ids, length, and rate.
///
/// This is the single run point for the estimator: Riverpod memoizes the future
/// per session, so the four output math channels (which each `await` this from
/// [mathChannelEvalProvider]) share one ~9 s run rather than triggering four. The
/// run is a `flutter_rust_bridge` async call — it executes off the UI isolate, so
/// the app never blocks; charts waiting on the outputs show the normal
/// math-channel loading spinner until it lands.
///
/// Kept alive (not `autoDispose`) so the ~9 s run is cached for the session's
/// lifetime — revisiting the Suspension sheet doesn't recompute. Retuning
/// [_defaultSuspensionConfig] needs a hot **restart** to clear the cache (which
/// also re-runs with the new config); config-keyed invalidation is a follow-up.
final suspensionEstimatorProvider =
    FutureProvider.family<rust.SuspensionEstimateMeta, String>((ref, sessionId) async {
  final handle = await ref.watch(sessionHandleProvider(sessionId).future);
  final meta = await rust.estimateSuspensionIntoStore(
    handle: handle,
    config: _defaultSuspensionConfig(),
  );
  // The outputs were (re)written into the store — drop any cached chart tiles so
  // the chart re-decimates the fresh data on the next paint.
  final cache = ref.read(chartTileCacheProvider);
  for (final id in meta.channelIds) {
    cache.invalidateChannelAcrossSessions(id);
  }
  return meta;
});
