import 'math_function_catalog.dart';

/// The chip-editor expression tree.
///
/// A structured representation of a math-channel expression: functions with
/// argument slots, channel references, numeric/string literals, and infix
/// operators. The tree serialises to the exact text the Rust engine consumes
/// ([toExpression]) and can be parsed back from that text ([parseExpression]),
/// so the chip editor and the raw-text editor stay interchangeable.
///
/// Nodes are **mutable** — the editor edits slots in place (assign a child,
/// clear a slot) and rebuilds. A `null` slot is an empty drop target.
sealed class ExprNode {
  /// Serialises this node to engine expression text. Incomplete slots emit the
  /// [incompletePlaceholder] sentinel, which never validates — callers gate on
  /// [isComplete] before persisting.
  String toExpression();

  /// True when this node and every descendant slot is filled.
  bool get isComplete;

  /// Deep copy — used when dropping a palette item so each placement is
  /// independent.
  ExprNode clone();
}

/// Sentinel emitted for an empty slot during serialisation. Chosen so it is
/// obviously invalid (the engine rejects a bare `?`).
const String incompletePlaceholder = '?';

/// A reference to a session or math channel, e.g. `[IMU1_AccelZ]`.
class ChannelNode extends ExprNode {
  /// The channel name without brackets.
  String name;

  /// Creates a [ChannelNode].
  ChannelNode(this.name);

  @override
  String toExpression() => '[$name]';

  @override
  bool get isComplete => name.isNotEmpty;

  @override
  ExprNode clone() => ChannelNode(name);
}

/// A numeric literal, e.g. `3.6`.
class NumberNode extends ExprNode {
  /// The scalar value.
  double value;

  /// Creates a [NumberNode].
  NumberNode(this.value);

  @override
  String toExpression() => formatNumber(value);

  @override
  bool get isComplete => true;

  @override
  ExprNode clone() => NumberNode(value);
}

/// A string literal, e.g. `"hann"`. Used for filter type and FFT window args.
class StringNode extends ExprNode {
  /// The string value without quotes.
  String value;

  /// Creates a [StringNode].
  StringNode(this.value);

  @override
  String toExpression() => '"$value"';

  @override
  bool get isComplete => value.isNotEmpty;

  @override
  ExprNode clone() => StringNode(value);
}

/// A function call with positional argument slots, e.g. `integrate([A])`.
class FunctionNode extends ExprNode {
  /// The function name; matches a [MathFunctionSpec] in the catalogue.
  final String name;

  /// Argument slots, one per [MathFunctionSpec.args]. `null` = empty slot.
  final List<ExprNode?> args;

  /// Creates a [FunctionNode] with [argCount] empty slots.
  FunctionNode(this.name, int argCount) : args = List.filled(argCount, null);

  /// Creates a [FunctionNode] from existing [args].
  FunctionNode.withArgs(this.name, this.args);

  /// The catalogue spec, or null if the name is unknown.
  MathFunctionSpec? get spec => kMathFunctionsByName[name];

  @override
  String toExpression() =>
      '$name(${args.map((a) => a?.toExpression() ?? incompletePlaceholder).join(', ')})';

  @override
  bool get isComplete => args.every((a) => a != null && a.isComplete);

  @override
  ExprNode clone() =>
      FunctionNode.withArgs(name, args.map((a) => a?.clone()).toList());
}

/// An infix binary operation, e.g. `([GPS_SpeedKmh] / 3.6)`.
class BinaryNode extends ExprNode {
  /// The operator glyph, e.g. `"/"`, `"+"`, `"=="`, `"and"`.
  final String op;

  /// Left operand slot.
  ExprNode? left;

  /// Right operand slot.
  ExprNode? right;

  /// Creates a [BinaryNode].
  BinaryNode(this.op, [this.left, this.right]);

  @override
  String toExpression() {
    final l = left?.toExpression() ?? incompletePlaceholder;
    final r = right?.toExpression() ?? incompletePlaceholder;
    return '($l $op $r)';
  }

  @override
  bool get isComplete =>
      left != null && left!.isComplete && right != null && right!.isComplete;

  @override
  ExprNode clone() => BinaryNode(op, left?.clone(), right?.clone());
}

/// A prefix unary operation: negation (`-x`) or logical not (`not x`).
class UnaryNode extends ExprNode {
  /// The operator, `"-"` or `"not"`.
  final String op;

  /// The operand slot.
  ExprNode? operand;

  /// Creates a [UnaryNode].
  UnaryNode(this.op, [this.operand]);

  @override
  String toExpression() {
    final o = operand?.toExpression() ?? incompletePlaceholder;
    return op == 'not' ? '(not $o)' : '(-$o)';
  }

  @override
  bool get isComplete => operand != null && operand!.isComplete;

  @override
  ExprNode clone() => UnaryNode(op, operand?.clone());
}

/// Formats [v] without a trailing `.0` for whole numbers.
String formatNumber(double v) {
  if (v.isFinite && v == v.roundToDouble() && v.abs() < 1e15) {
    return v.toInt().toString();
  }
  return v.toString();
}

// ---------------------------------------------------------------------------
// Parser — best-effort text → tree
// ---------------------------------------------------------------------------

/// Parses [source] into an [ExprNode] tree, or returns null if it cannot be
/// represented as chips (the caller then keeps the user in raw-text mode).
///
/// Mirrors the Rust grammar's precedence: or → and → comparison → additive →
/// multiplicative → unary → primary. Best-effort: any malformed or unsupported
/// construct yields null rather than throwing.
ExprNode? parseExpression(String source) {
  if (source.trim().isEmpty) return null;
  try {
    final tokens = _tokenize(source);
    if (tokens.isEmpty) return null;
    final parser = _Parser(tokens);
    final node = parser._parseOr();
    if (!parser._atEnd) return null; // trailing garbage
    return node;
  } catch (_) {
    return null;
  }
}

// ---- Tokenizer ------------------------------------------------------------

enum _Tk { number, string, channel, ident, op, lparen, rparen, comma }

class _Token {
  final _Tk kind;
  final String text;
  const _Token(this.kind, this.text);
}

List<_Token> _tokenize(String s) {
  final tokens = <_Token>[];
  var i = 0;
  const ops = {
    '+', '-', '*', '/', '<', '>', '<=', '>=', '==', '!=', //
  };
  while (i < s.length) {
    final c = s[i];
    if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
      i++;
      continue;
    }
    if (c == '(') {
      tokens.add(const _Token(_Tk.lparen, '('));
      i++;
      continue;
    }
    if (c == ')') {
      tokens.add(const _Token(_Tk.rparen, ')'));
      i++;
      continue;
    }
    if (c == ',') {
      tokens.add(const _Token(_Tk.comma, ','));
      i++;
      continue;
    }
    if (c == '[') {
      final end = s.indexOf(']', i + 1);
      if (end < 0) throw const FormatException('unclosed [');
      tokens.add(_Token(_Tk.channel, s.substring(i + 1, end)));
      i = end + 1;
      continue;
    }
    if (c == '"') {
      final end = s.indexOf('"', i + 1);
      if (end < 0) throw const FormatException('unclosed "');
      tokens.add(_Token(_Tk.string, s.substring(i + 1, end)));
      i = end + 1;
      continue;
    }
    // Two-char operators first.
    if (i + 1 < s.length && ops.contains(s.substring(i, i + 2))) {
      tokens.add(_Token(_Tk.op, s.substring(i, i + 2)));
      i += 2;
      continue;
    }
    if (ops.contains(c)) {
      tokens.add(_Token(_Tk.op, c));
      i++;
      continue;
    }
    // Number (leading digit or dot).
    if (_isDigit(c) || (c == '.' && i + 1 < s.length && _isDigit(s[i + 1]))) {
      final start = i;
      while (i < s.length && (_isDigit(s[i]) || s[i] == '.')) {
        i++;
      }
      // optional exponent
      if (i < s.length && (s[i] == 'e' || s[i] == 'E')) {
        i++;
        if (i < s.length && (s[i] == '+' || s[i] == '-')) i++;
        while (i < s.length && _isDigit(s[i])) {
          i++;
        }
      }
      tokens.add(_Token(_Tk.number, s.substring(start, i)));
      continue;
    }
    // Identifier / keyword.
    if (_isIdentStart(c)) {
      final start = i;
      while (i < s.length && _isIdentPart(s[i])) {
        i++;
      }
      tokens.add(_Token(_Tk.ident, s.substring(start, i)));
      continue;
    }
    throw FormatException('unexpected character "$c"');
  }
  return tokens;
}

bool _isDigit(String c) => c.codeUnitAt(0) >= 48 && c.codeUnitAt(0) <= 57;
bool _isIdentStart(String c) {
  final u = c.codeUnitAt(0);
  return (u >= 65 && u <= 90) || (u >= 97 && u <= 122) || c == '_';
}

bool _isIdentPart(String c) => _isIdentStart(c) || _isDigit(c);

// ---- Recursive-descent parser --------------------------------------------

class _Parser {
  final List<_Token> _t;
  int _pos = 0;

  _Parser(this._t);

  bool get _atEnd => _pos >= _t.length;
  _Token get _peek => _t[_pos];
  _Token _next() => _t[_pos++];

  bool _matchOp(Set<String> ops) {
    if (_atEnd) return false;
    final tk = _peek;
    final isKeyword = tk.kind == _Tk.ident && ops.contains(tk.text);
    final isOp = tk.kind == _Tk.op && ops.contains(tk.text);
    return isKeyword || isOp;
  }

  ExprNode _parseOr() {
    var node = _parseAnd();
    while (_matchOp({'or'})) {
      _next();
      node = BinaryNode('or', node, _parseAnd());
    }
    return node;
  }

  ExprNode _parseAnd() {
    var node = _parseCmp();
    while (_matchOp({'and'})) {
      _next();
      node = BinaryNode('and', node, _parseCmp());
    }
    return node;
  }

  ExprNode _parseCmp() {
    var node = _parseAdd();
    while (_matchOp({'<', '>', '<=', '>=', '==', '!='})) {
      final op = _next().text;
      node = BinaryNode(op, node, _parseAdd());
    }
    return node;
  }

  ExprNode _parseAdd() {
    var node = _parseMul();
    while (_matchOp({'+', '-'})) {
      final op = _next().text;
      node = BinaryNode(op, node, _parseMul());
    }
    return node;
  }

  ExprNode _parseMul() {
    var node = _parseUnary();
    while (_matchOp({'*', '/'})) {
      final op = _next().text;
      node = BinaryNode(op, node, _parseUnary());
    }
    return node;
  }

  ExprNode _parseUnary() {
    if (_matchOp({'-', 'not'})) {
      final op = _next().text;
      return UnaryNode(op, _parseUnary());
    }
    return _parsePrimary();
  }

  ExprNode _parsePrimary() {
    final tk = _next();
    switch (tk.kind) {
      case _Tk.number:
        return NumberNode(double.parse(tk.text));
      case _Tk.string:
        return StringNode(tk.text);
      case _Tk.channel:
        return ChannelNode(tk.text);
      case _Tk.lparen:
        final inner = _parseOr();
        if (_atEnd || _next().kind != _Tk.rparen) {
          throw const FormatException('missing )');
        }
        return inner;
      case _Tk.ident:
        // Function call: ident '(' args ')'
        if (!_atEnd && _peek.kind == _Tk.lparen) {
          _next(); // consume '('
          final args = <ExprNode?>[];
          if (!_atEnd && _peek.kind != _Tk.rparen) {
            args.add(_parseOr());
            while (!_atEnd && _peek.kind == _Tk.comma) {
              _next();
              args.add(_parseOr());
            }
          }
          if (_atEnd || _next().kind != _Tk.rparen) {
            throw const FormatException('missing ) in call');
          }
          return FunctionNode.withArgs(tk.text, args);
        }
        // Bare identifier is not representable as a chip.
        throw FormatException('bare identifier "${tk.text}"');
      default:
        throw FormatException('unexpected token "${tk.text}"');
    }
  }
}
