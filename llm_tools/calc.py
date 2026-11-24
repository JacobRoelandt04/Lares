#!/usr/bin/env python3
"""calculator: evaluate ONE expression through an AST allowlist.

    python3 -I -S calc.py -- '<expression>'

The text is parsed with ast.parse in eval mode and evaluated by the small
recursive evaluator below -- never by eval() on the text. Only the node kinds
it knows are allowed; calls only to math.* and to a handful of builtins;
anything else is refused with the node's name (`not allowed: Attribute`).
A power is bounded before it is computed (9**9**9 would otherwise sit on the
CPU until the runner's timeout), and the process caps its own CPU time and
memory as a second belt.
"""
import ast
import math
import resource
import sys

BUILTINS = {"abs": abs, "round": round, "min": min, "max": max, "sum": sum,
            "len": len, "int": int, "float": float}
NAMES = {"pi": math.pi, "e": math.e, "tau": math.tau, "inf": math.inf,
         "True": True, "False": False}
BIN = {ast.Add: lambda a, b: a + b, ast.Sub: lambda a, b: a - b,
       ast.Mult: lambda a, b: a * b, ast.Div: lambda a, b: a / b,
       ast.FloorDiv: lambda a, b: a // b, ast.Mod: lambda a, b: a % b,
       ast.BitAnd: lambda a, b: a & b, ast.BitOr: lambda a, b: a | b,
       ast.BitXor: lambda a, b: a ^ b, ast.LShift: lambda a, b: a << b,
       ast.RShift: lambda a, b: a >> b}
CMP = {ast.Eq: lambda a, b: a == b, ast.NotEq: lambda a, b: a != b,
       ast.Lt: lambda a, b: a < b, ast.LtE: lambda a, b: a <= b,
       ast.Gt: lambda a, b: a > b, ast.GtE: lambda a, b: a >= b}
MAX_POW_DIGITS = 5000


class NotAllowed(ValueError):
    pass


def power(a, b):
    if isinstance(b, complex) or isinstance(a, complex):
        raise NotAllowed("not allowed: complex power")
    if isinstance(b, (int, float)) and abs(b) > 100000:
        raise NotAllowed("not allowed: exponent above 100000")
    if isinstance(a, int) and isinstance(b, int) and b > 0 and abs(a) > 1:
        if b * math.log10(abs(a)) > MAX_POW_DIGITS:
            raise NotAllowed("not allowed: the result would exceed %d digits" % MAX_POW_DIGITS)
    return a ** b


def ev(n):
    if isinstance(n, ast.Expression):
        return ev(n.body)
    if isinstance(n, ast.Constant):
        if isinstance(n.value, bool) or isinstance(n.value, (int, float, complex)):
            return n.value
        raise NotAllowed("not allowed: constant " + type(n.value).__name__)
    if isinstance(n, ast.Name):
        if n.id in NAMES:
            return NAMES[n.id]
        raise NotAllowed("not allowed: name " + n.id)
    if isinstance(n, ast.Attribute):
        if isinstance(n.value, ast.Name) and n.value.id == "math" and not n.attr.startswith("_") and hasattr(math, n.attr):
            v = getattr(math, n.attr)
            if callable(v):
                raise NotAllowed("not allowed: math." + n.attr + " must be called")
            return v
        raise NotAllowed("not allowed: attribute " + n.attr)
    if isinstance(n, ast.UnaryOp):
        v = ev(n.operand)
        if isinstance(n.op, ast.USub):
            return -v
        if isinstance(n.op, ast.UAdd):
            return +v
        if isinstance(n.op, ast.Not):
            return not v
        if isinstance(n.op, ast.Invert):
            return ~v
        raise NotAllowed("not allowed: " + type(n.op).__name__)
    if isinstance(n, ast.BinOp):
        a = ev(n.left)
        b = ev(n.right)
        if isinstance(n.op, ast.Pow):
            return power(a, b)
        f = BIN.get(type(n.op))
        if f is None:
            raise NotAllowed("not allowed: " + type(n.op).__name__)
        if isinstance(n.op, ast.LShift) and isinstance(b, int) and b > 100000:
            raise NotAllowed("not allowed: shift above 100000")
        return f(a, b)
    if isinstance(n, ast.BoolOp):
        vals = [ev(v) for v in n.values]
        if isinstance(n.op, ast.And):
            return all(vals)
        return any(vals)
    if isinstance(n, ast.Compare):
        left = ev(n.left)
        for op, comp in zip(n.ops, n.comparators):
            f = CMP.get(type(op))
            if f is None:
                raise NotAllowed("not allowed: " + type(op).__name__)
            right = ev(comp)
            if not f(left, right):
                return False
            left = right
        return True
    if isinstance(n, ast.IfExp):
        return ev(n.body) if ev(n.test) else ev(n.orelse)
    if isinstance(n, (ast.Tuple, ast.List)):
        return [ev(e) for e in n.elts]
    if isinstance(n, ast.Call):
        if n.keywords:
            raise NotAllowed("not allowed: keyword arguments")
        f = n.func
        if isinstance(f, ast.Attribute) and isinstance(f.value, ast.Name) and f.value.id == "math" \
                and not f.attr.startswith("_") and callable(getattr(math, f.attr, None)):
            fn = getattr(math, f.attr)
        elif isinstance(f, ast.Name) and f.id in BUILTINS:
            fn = BUILTINS[f.id]
        else:
            raise NotAllowed("not allowed: call")
        args = [ev(a) for a in n.args]
        for a in args:
            if isinstance(a, int) and abs(a) > 10 ** 12 and fn in (math.factorial, math.comb, math.perm):
                raise NotAllowed("not allowed: argument too large for " + f.attr)
        return fn(*args)
    raise NotAllowed("not allowed: " + type(n).__name__)


def main():
    try:
        resource.setrlimit(resource.RLIMIT_CPU, (3, 3))
        resource.setrlimit(resource.RLIMIT_AS, (512 * 1024 * 1024, 512 * 1024 * 1024))
    except (ValueError, OSError):
        pass
    args = sys.argv[1:]
    if args and args[0] == "--":
        args = args[1:]
    if len(args) != 1:
        print("usage: calc.py -- <expression>", file=sys.stderr)
        return 2
    text = args[0].strip()
    if len(text) > 1000:
        print("expression longer than 1000 characters", file=sys.stderr)
        return 2
    try:
        value = ev(ast.parse(text, mode="eval"))
    except ZeroDivisionError:
        print("division by zero", file=sys.stderr)
        return 1
    except (ValueError, SyntaxError, TypeError, OverflowError, MemoryError, RecursionError) as e:
        print(str(e), file=sys.stderr)
        return 1
    try:
        if isinstance(value, float) and value == int(value) and abs(value) < 1e15:
            print(int(value))
        else:
            print(value)
    except (ValueError, OverflowError) as e:
        print("result too large to print: %s" % e, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
