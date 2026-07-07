"""
AMPL tokenizer. Treats all whitespace (spaces, tabs, newlines) as equivalent
token separators. Produces a stream of tokens consumed by the parser.

Inspired by MathOptInterface/src/FileFormats/LP/read.jl.
"""

@enum(
    TokenKind,
    TOKEN_IDENTIFIER,  # foo, x1, _bar
    TOKEN_STRING,      # 'foo' or "foo" — AMPL string literal
    TOKEN_NUMBER,      # 42, 3.14, 1e-7, -5
    TOKEN_SEMICOLON,   # ;
    TOKEN_COLON,       # :
    TOKEN_COMMA,       # ,
    TOKEN_ASSIGN,      # :=
    TOKEN_DOTDOT,      # ..
    TOKEN_DOT,         # .  (missing value in .dat)
    TOKEN_LBRACE,      # {
    TOKEN_RBRACE,      # }
    TOKEN_LBRACKET,    # [
    TOKEN_RBRACKET,    # ]
    TOKEN_LPAREN,      # (
    TOKEN_RPAREN,      # )
    TOKEN_PLUS,        # +
    TOKEN_MINUS,       # -
    TOKEN_STAR,        # *
    TOKEN_STARSTAR,    # **
    TOKEN_SLASH,       # /
    TOKEN_CARET,       # ^
    TOKEN_GEQ,         # >=
    TOKEN_LEQ,         # <=
    TOKEN_EQ,          # == or =
    TOKEN_NEQ,         # <> or !=
    TOKEN_LT,          # <
    TOKEN_GT,          # >
    TOKEN_AND,         # && or and
    TOKEN_OR,          # || or or
    TOKEN_NOT,         # ! or not
    TOKEN_EOF,         # end of input
)

struct Token
    kind::TokenKind
    value::String
end

mutable struct Lexer
    input::String
    pos::Int
    tokens::Vector{Token}  # buffered lookahead
end

function Lexer(input::String)
    return Lexer(input, 1, Token[])
end

@inline _advance!(lex::Lexer) = (lex.pos = nextind(lex.input, lex.pos); nothing)

function _skip_whitespace_and_comments!(lex::Lexer)
    while lex.pos <= ncodeunits(lex.input)
        c = lex.input[lex.pos]
        if c == '#'
            # Skip to end of line
            while lex.pos <= ncodeunits(lex.input) && lex.input[lex.pos] != '\n'
                _advance!(lex)
            end
        elseif c == '/' &&
               lex.pos + 1 <= ncodeunits(lex.input) &&
               lex.input[lex.pos+1] == '*'
            # C-style block comment /* ... */
            lex.pos += 2
            while lex.pos + 1 <= ncodeunits(lex.input)
                if lex.input[lex.pos] == '*' && lex.input[lex.pos+1] == '/'
                    lex.pos += 2
                    break
                end
                _advance!(lex)
            end
        elseif isspace(c)
            _advance!(lex)
        else
            return
        end
    end
    return
end

function _read_number!(lex::Lexer)
    start = lex.pos
    # Optional leading sign is already consumed or not present
    while lex.pos <= ncodeunits(lex.input)
        c = lex.input[lex.pos]
        if isdigit(c) || c == '.'
            # Check for `..` — that's TOKEN_DOTDOT, not part of number
            if c == '.'
                if lex.pos + 1 <= ncodeunits(lex.input) &&
                   lex.input[lex.pos+1] == '.'
                    break
                end
                # Check that next char is a digit (otherwise it's ambiguous)
                if lex.pos + 1 <= ncodeunits(lex.input) &&
                   !isdigit(lex.input[lex.pos+1]) &&
                   !_is_exponent_char(lex.input[lex.pos+1])
                    # Include trailing dot (e.g., "2." in "2./3")
                    lex.pos += 1
                    break
                end
            end
            lex.pos += 1
        elseif _is_exponent_char(c)
            # `d`/`D` is the Fortran exponent marker kept by CUTE-derived
            # models (lukvle9's `1.d-4`); only treat it as one when a
            # digit or sign follows, so `2*d` still lexes `d` as an
            # identifier.
            if c in ('d', 'D') && !(
                lex.pos + 1 <= ncodeunits(lex.input) && (
                    isdigit(lex.input[lex.pos+1]) ||
                    lex.input[lex.pos+1] in ('+', '-')
                )
            )
                break
            end
            lex.pos += 1
            if lex.pos <= ncodeunits(lex.input) &&
               (lex.input[lex.pos] == '+' || lex.input[lex.pos] == '-')
                lex.pos += 1
            end
        else
            break
        end
    end
    return Token(TOKEN_NUMBER, _normalize_number(lex.input[start:(lex.pos-1)]))
end

_is_exponent_char(c::Char) = c in ('e', 'E', 'd', 'D')

# Rewrite AMPL/Fortran number spellings that Julia's parser rejects:
# leading-dot floats (`.5` → `0.5`), trailing-dot floats (`2.` → `2.0`),
# and `d`/`D` exponents (`1.d-4` → `1.0e-4`).
function _normalize_number(s::AbstractString)
    s = replace(s, r"[dD]" => "e")
    if startswith(s, ".")
        s = "0" * s
    end
    s = replace(s, r"\.(?=$|[eE])" => ".0")
    return s
end

function _read_identifier!(lex::Lexer)
    start = lex.pos
    while lex.pos <= ncodeunits(lex.input)
        c = lex.input[lex.pos]
        if isdigit(c) || isletter(c) || c == '_'
            _advance!(lex)
        else
            break
        end
    end
    return Token(TOKEN_IDENTIFIER, lex.input[start:prevind(lex.input, lex.pos)])
end

function _next_token!(lex::Lexer)
    _skip_whitespace_and_comments!(lex)
    if lex.pos > ncodeunits(lex.input)
        return Token(TOKEN_EOF, "")
    end
    c = lex.input[lex.pos]
    # Two-character operators (check first)
    if lex.pos + 1 <= ncodeunits(lex.input)
        c2 = lex.input[lex.pos+1]
        if c == ':' && c2 == '='
            lex.pos += 2
            return Token(TOKEN_ASSIGN, ":=")
        elseif c == '.' && c2 == '.'
            lex.pos += 2
            return Token(TOKEN_DOTDOT, "..")
        elseif c == '*' && c2 == '*'
            lex.pos += 2
            return Token(TOKEN_STARSTAR, "**")
        elseif c == '>' && c2 == '='
            lex.pos += 2
            return Token(TOKEN_GEQ, ">=")
        elseif c == '<' && c2 == '='
            lex.pos += 2
            return Token(TOKEN_LEQ, "<=")
        elseif c == '=' && c2 == '='
            lex.pos += 2
            return Token(TOKEN_EQ, "==")
        elseif c == '<' && c2 == '>'
            lex.pos += 2
            return Token(TOKEN_NEQ, "<>")
        elseif c == '!' && c2 == '='
            lex.pos += 2
            return Token(TOKEN_NEQ, "!=")
        elseif c == '&' && c2 == '&'
            lex.pos += 2
            return Token(TOKEN_AND, "&&")
        elseif c == '|' && c2 == '|'
            lex.pos += 2
            return Token(TOKEN_OR, "||")
        end
    end
    # Single-character tokens
    if c == ';'
        lex.pos += 1
        return Token(TOKEN_SEMICOLON, ";")
    elseif c == ':'
        lex.pos += 1
        return Token(TOKEN_COLON, ":")
    elseif c == ','
        lex.pos += 1
        return Token(TOKEN_COMMA, ",")
    elseif c == '.'
        # Leading-dot float: .38 → TOKEN_NUMBER "0.38"
        if lex.pos + 1 <= ncodeunits(lex.input) && isdigit(lex.input[lex.pos+1])
            return _read_number!(lex)
        end
        lex.pos += 1
        return Token(TOKEN_DOT, ".")
    elseif c == '{'
        lex.pos += 1
        return Token(TOKEN_LBRACE, "{")
    elseif c == '}'
        lex.pos += 1
        return Token(TOKEN_RBRACE, "}")
    elseif c == '['
        lex.pos += 1
        return Token(TOKEN_LBRACKET, "[")
    elseif c == ']'
        lex.pos += 1
        return Token(TOKEN_RBRACKET, "]")
    elseif c == '('
        lex.pos += 1
        return Token(TOKEN_LPAREN, "(")
    elseif c == ')'
        lex.pos += 1
        return Token(TOKEN_RPAREN, ")")
    elseif c == '+'
        lex.pos += 1
        return Token(TOKEN_PLUS, "+")
    elseif c == '-'
        lex.pos += 1
        return Token(TOKEN_MINUS, "-")
    elseif c == '*'
        lex.pos += 1
        return Token(TOKEN_STAR, "*")
    elseif c == '/'
        lex.pos += 1
        return Token(TOKEN_SLASH, "/")
    elseif c == '^'
        lex.pos += 1
        return Token(TOKEN_CARET, "^")
    elseif c == '>'
        lex.pos += 1
        return Token(TOKEN_GT, ">")
    elseif c == '<'
        lex.pos += 1
        return Token(TOKEN_LT, "<")
    elseif c == '='
        lex.pos += 1
        return Token(TOKEN_EQ, "=")
    elseif c == '!'
        lex.pos += 1
        return Token(TOKEN_NOT, "!")
    elseif c == '&'
        lex.pos += 1
        return Token(TOKEN_AND, "&")
    elseif c == '|'
        lex.pos += 1
        return Token(TOKEN_OR, "|")
    elseif isdigit(c)
        return _read_number!(lex)
    elseif isletter(c) || c == '_'
        return _read_identifier!(lex)
    elseif c == '\'' || c == '"'
        return _read_string!(lex, c)
    else
        error("Unexpected character '$(c)' at position $(lex.pos)")
    end
end

function _read_string!(lex::Lexer, quote_char::Char)
    lex.pos += 1  # consume opening quote (always ASCII)
    start = lex.pos
    while lex.pos <= ncodeunits(lex.input) && lex.input[lex.pos] != quote_char
        _advance!(lex)
    end
    val = lex.input[start:prevind(lex.input, lex.pos)]
    if lex.pos <= ncodeunits(lex.input)
        lex.pos += 1  # consume closing quote (always ASCII)
    end
    return Token(TOKEN_STRING, val)
end

"""
    peek(lex::Lexer, n::Int = 1)

Look ahead at the n-th token without consuming it.
"""
function peek(lex::Lexer, n::Int = 1)
    while length(lex.tokens) < n
        push!(lex.tokens, _next_token!(lex))
    end
    return lex.tokens[n]
end

"""
    read_token!(lex::Lexer)

Consume and return the next token.
"""
function read_token!(lex::Lexer)
    if !isempty(lex.tokens)
        return popfirst!(lex.tokens)
    end
    return _next_token!(lex)
end

"""
    expect!(lex::Lexer, kind::TokenKind)

Consume the next token and assert it has the expected kind.
"""
function expect!(lex::Lexer, kind::TokenKind)
    t = read_token!(lex)
    if t.kind != kind
        error("Expected $(kind) but got $(t.kind) '$(t.value)'")
    end
    return t
end

"""
    read_until!(lex::Lexer, stop::TokenKind)

Read all tokens until (but not including) a token of kind `stop`.
Returns the concatenated text with spaces between tokens.
"""
function read_until!(lex::Lexer, stop::TokenKind)
    parts = String[]
    while true
        t = peek(lex)
        if t.kind == stop || t.kind == TOKEN_EOF
            break
        end
        read_token!(lex)
        push!(parts, t.value)
    end
    return join(parts, " ")
end

"""
    read_until!(lex::Lexer, stops::NTuple{N,TokenKind})

Read all tokens until any of the stop kinds is reached.
"""
function read_until!(lex::Lexer, stops::NTuple{N,TokenKind}) where {N}
    parts = String[]
    while true
        t = peek(lex)
        if t.kind in stops || t.kind == TOKEN_EOF
            break
        end
        read_token!(lex)
        push!(parts, t.value)
    end
    return join(parts, " ")
end

"""
    read_balanced!(lex::Lexer, open::TokenKind, close::TokenKind)

Read tokens including balanced open/close pairs. The opening token
should already be consumed. Returns text inside (not including the
closing token which is consumed).
"""
function read_balanced!(
    lex::Lexer,
    open::TokenKind,
    close::TokenKind;
    compact::Bool = false,
)
    parts = String[]
    prev_kind = nothing
    depth = 1
    while depth > 0
        t = read_token!(lex)
        if t.kind == TOKEN_EOF
            error("Unexpected end of input, expected $(close)")
        end
        if t.kind == open
            depth += 1
        elseif t.kind == close
            depth -= 1
            if depth == 0
                break
            end
        end
        if !isempty(parts) && _needs_space(prev_kind, t.kind; compact)
            push!(parts, " ")
        end
        push!(parts, emit_token(t))
        prev_kind = t.kind
    end
    return join(parts)
end

# AMPL string literals (`'foo'` / `"foo"`) come through the lexer as
# `TOKEN_STRING`; when echoed back into a Julia expression they must be
# quoted so the emitted code references them as `String`s (e.g. a
# set member used as an index) rather than as bare identifiers.
emit_token(t::Token) = t.kind == TOKEN_STRING ? repr(t.value) : t.value

const _ARITH_OPS = (
    TOKEN_PLUS,
    TOKEN_MINUS,
    TOKEN_STAR,
    TOKEN_SLASH,
    TOKEN_CARET,
    TOKEN_STARSTAR,
)

const _COMP_OPS =
    (TOKEN_GEQ, TOKEN_LEQ, TOKEN_EQ, TOKEN_NEQ, TOKEN_LT, TOKEN_GT)

function _needs_space(
    prev::Union{Nothing,TokenKind},
    curr::TokenKind;
    compact::Bool = false,
)
    isnothing(prev) && return false
    # No space after open or before close
    prev in (TOKEN_LPAREN, TOKEN_LBRACE, TOKEN_LBRACKET) && return false
    curr in (TOKEN_RPAREN, TOKEN_RBRACE, TOKEN_RBRACKET) && return false
    # No space before/after comma
    curr == TOKEN_COMMA && return false
    prev == TOKEN_COMMA && return true
    # No space around dots (for ..)
    (curr == TOKEN_DOT || curr == TOKEN_DOTDOT) && return false
    prev == TOKEN_DOTDOT && return false
    # No space between identifier/number and open bracket/paren
    if curr in (TOKEN_LBRACKET, TOKEN_LPAREN) &&
       prev in (TOKEN_IDENTIFIER, TOKEN_NUMBER, TOKEN_RPAREN, TOKEN_RBRACKET)
        return false
    end
    # Space after close bracket/paren before identifier/number (e.g. "(i,j,k) in S")
    if prev in (TOKEN_RPAREN, TOKEN_RBRACE, TOKEN_RBRACKET) &&
       curr in (TOKEN_IDENTIFIER, TOKEN_NUMBER)
        return true
    end
    # Space between identifier/number and identifier/number
    if prev in (TOKEN_IDENTIFIER, TOKEN_NUMBER) &&
       curr in (TOKEN_IDENTIFIER, TOKEN_NUMBER)
        return true
    end
    # Space around comparison operators always
    if curr in _COMP_OPS || prev in _COMP_OPS
        return true
    end
    # Space around arithmetic operators in non-compact mode
    if !compact && (curr in _ARITH_OPS || prev in _ARITH_OPS)
        return true
    end
    return false
end
