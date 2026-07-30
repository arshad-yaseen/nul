/// <reference types="tree-sitter-cli/dsl" />
// @ts-check

// The grammar mirrors compiler/Parse.zig. Where the two could drift, the
// compiler is right and this file is wrong: it exists to colour and outline
// source, not to accept or reject it.
//
// One deliberate difference. The compiler's tokenizer inserts a `;` at a
// newline that follows a value (`Token.endsStatement`), so a statement ends
// without one being written. Tree-sitter has no such rule, and adding it would
// mean an external scanner. Instead statements here are delimited by structure
// and `;` is optional. The two disagree only where a line begins with `(`,
// `[`, `.`, or a binary operator, which continues the line above rather than
// starting a statement. No such line is a valid statement in Nul, so every
// program the compiler accepts parses the same way here.

const PREC = {
  or: 1,
  and: 2,
  comparison: 3,
  // `orelse` and `catch` supply a value: looser than arithmetic, tighter than
  // comparison, and right-nesting, so `a orelse b orelse c` tries each in turn.
  supply: 4,
  additive: 5,
  multiplicative: 6,
  unary: 7,
  suffix: 8,
};

module.exports = grammar({
  name: 'nul',

  // `word` keeps a keyword from matching the head of an identifier, so
  // `iffy` is one name and not `if` followed by `fy`.
  word: ($) => $.identifier,

  extras: ($) => [/\s/, $.comment, $.doc_comment, $.file_doc_comment],

  supertypes: ($) => [$._declaration, $._statement, $._expression, $._type],

  rules: {
    source_file: ($) => repeat($._declaration),

    // declarations

    _declaration: ($) =>
      choice(
        $.use_declaration,
        $.struct_declaration,
        $.type_declaration,
        $.function_declaration,
        $.variable_declaration,
      ),

    use_declaration: ($) =>
      seq(optional('pub'), 'use', field('path', $._name), optional(';')),

    struct_declaration: ($) =>
      seq(
        optional('pub'),
        'struct',
        field('name', $.identifier),
        optional(field('type_parameters', $.type_parameters)),
        field('body', $.struct_body),
      ),

    struct_body: ($) =>
      seq('{', repeat(choice($.field_declaration, $.function_declaration)), '}'),

    field_declaration: ($) =>
      seq(
        field('name', $.identifier),
        ':',
        field('type', $._type),
        optional(';'),
      ),

    type_declaration: ($) =>
      seq(
        optional('pub'),
        'type',
        field('name', $.identifier),
        '=',
        field('value', $._type),
        optional(';'),
      ),

    function_declaration: ($) =>
      seq(
        optional('pub'),
        'fn',
        field('name', $.identifier),
        optional(field('type_parameters', $.type_parameters)),
        field('parameters', $.parameters),
        optional(field('return_type', $._type)),
        choice(
          field('body', $.block),
          seq('=', field('body', $._expression), optional(';')),
        ),
      ),

    type_parameters: ($) =>
      seq('[', commaSep1($.type_parameter), optional(','), ']'),

    type_parameter: ($) => $.identifier,

    parameters: ($) => seq('(', commaSep($.parameter), optional(','), ')'),

    parameter: ($) =>
      seq(field('name', $.identifier), ':', field('type', $._type)),

    // A `let` at the top level, a `let` or `var` inside a body. Which one it is
    // reads off the keyword, the same way the compiler tells them apart.
    variable_declaration: ($) =>
      seq(
        optional('pub'),
        field('kind', choice('let', 'var')),
        field('name', $.identifier),
        optional(seq(':', field('type', $._type))),
        '=',
        field('value', $._expression),
        optional(';'),
      ),

    // statements

    block: ($) => seq('{', repeat($._statement), '}'),

    _statement: ($) =>
      choice(
        $.variable_declaration,
        $.if_statement,
        $.while_statement,
        $.break_statement,
        $.continue_statement,
        $.return_statement,
        $.defer_statement,
        $.assignment_statement,
        $.expression_statement,
      ),

    // No parentheses around the condition, and braces are mandatory, so no arm
    // can dangle. An `else if` nests as another `if_statement`.
    if_statement: ($) =>
      seq(
        'if',
        field('condition', $._expression),
        optional(field('capture', $.capture)),
        field('consequence', $.block),
        optional(
          seq('else', field('alternative', choice($.block, $.if_statement))),
        ),
      ),

    // No condition is `while { }`, which only a `break` or `return` leaves.
    while_statement: ($) =>
      seq(
        'while',
        optional(field('condition', $._expression)),
        optional(field('capture', $.capture)),
        field('body', $.block),
      ),

    // `|v|`, naming what an optional held or what error a `catch` caught.
    capture: ($) => seq('|', field('name', $.identifier), '|'),

    break_statement: (_) => seq('break', optional(';')),

    continue_statement: (_) => seq('continue', optional(';')),

    // `prec.right` makes a `return` take the expression that follows it. The
    // compiler ends the statement at the newline instead, so the two differ
    // only for a `return` alone on its line with an expression statement under
    // it, which is unreachable code either way.
    return_statement: ($) =>
      prec.right(
        seq('return', optional(field('value', $._expression)), optional(';')),
      ),

    defer_statement: ($) =>
      seq('defer', field('body', $._expression), optional(';')),

    // The left side is any expression so the two statement forms share a
    // prefix and part on the `=`. `1 = x` parses and the compiler rejects it,
    // which is where that error belongs.
    assignment_statement: ($) =>
      seq(
        field('left', $._expression),
        '=',
        field('right', $._expression),
        optional(';'),
      ),

    expression_statement: ($) => seq($._expression, optional(';')),

    // expressions

    _expression: ($) =>
      choice(
        $.identifier,
        $.number_literal,
        $.string_literal,
        $.boolean_literal,
        $.null_literal,
        $.error_value,
        $.struct_literal,
        $.call_expression,
        $.instance_expression,
        $.field_expression,
        $.parenthesized_expression,
        $.unary_expression,
        $.binary_expression,
        $.try_expression,
        $.orelse_expression,
        $.catch_expression,
      ),

    parenthesized_expression: ($) => seq('(', $._expression, ')'),

    call_expression: ($) =>
      prec(
        PREC.suffix,
        seq(field('function', $._expression), field('arguments', $.arguments)),
      ),

    arguments: ($) => seq('(', commaSep($._expression), optional(','), ')'),

    // `Box[i64]` in a type and `create[Node]` in a call are the same thing, so
    // they carry the same argument list.
    instance_expression: ($) =>
      prec(
        PREC.suffix,
        seq(
          field('function', $._expression),
          field('type_arguments', $.type_arguments),
        ),
      ),

    field_expression: ($) =>
      prec(
        PREC.suffix,
        seq(field('object', $._expression), '.', field('field', $.identifier)),
      ),

    // `.{ field: value }`, whose type comes from context.
    struct_literal: ($) =>
      seq(
        '.',
        '{',
        commaSep($.field_initializer),
        optional(','),
        '}',
      ),

    field_initializer: ($) =>
      seq(field('name', $.identifier), ':', field('value', $._expression)),

    // `error.Name`, a member of the one universal error set.
    error_value: ($) => seq('error', '.', field('name', $.identifier)),

    try_expression: ($) =>
      prec.right(PREC.unary, seq('try', field('value', $._expression))),

    unary_expression: ($) =>
      prec.right(
        PREC.unary,
        seq(
          field('operator', choice('-', '!', '&')),
          field('operand', $._expression),
        ),
      ),

    // The right side may be a block, which is how `a orelse { return }` reads.
    orelse_expression: ($) =>
      prec.right(
        PREC.supply,
        seq(
          field('left', $._expression),
          'orelse',
          field('right', choice($._expression, $.block)),
        ),
      ),

    catch_expression: ($) =>
      prec.right(
        PREC.supply,
        seq(
          field('left', $._expression),
          'catch',
          optional(field('capture', $.capture)),
          field('right', choice($._expression, $.block)),
        ),
      ),

    binary_expression: ($) => {
      const table = [
        [PREC.or, 'or'],
        [PREC.and, 'and'],
        [PREC.comparison, '=='],
        [PREC.comparison, '!='],
        [PREC.comparison, '<'],
        [PREC.comparison, '<='],
        [PREC.comparison, '>'],
        [PREC.comparison, '>='],
        [PREC.additive, '+'],
        [PREC.additive, '-'],
        [PREC.multiplicative, '*'],
        [PREC.multiplicative, '/'],
        [PREC.multiplicative, '%'],
      ];

      return choice(
        ...table.map(([precedence, operator]) =>
          prec.left(
            /** @type {number} */ (precedence),
            seq(
              field('left', $._expression),
              field('operator', /** @type {string} */ (operator)),
              field('right', $._expression),
            ),
          ),
        ),
      );
    },

    // types

    _type: ($) =>
      choice(
        $.pointer_type,
        $.optional_type,
        $.error_union_type,
        $.generic_type,
        $._name,
      ),

    // `*T` reads, `*var T` writes.
    pointer_type: ($) =>
      seq('*', optional('var'), field('child', $._type)),

    optional_type: ($) => seq('?', field('child', $._type)),

    // `!T`, over the one universal error set, so it names nothing.
    error_union_type: ($) => seq('!', field('child', $._type)),

    generic_type: ($) =>
      seq(
        field('name', $._name),
        field('type_arguments', $.type_arguments),
      ),

    type_arguments: ($) => seq('[', commaSep1($._type), optional(','), ']'),

    // A dotted name: the head of a type, or the path of a `use`.
    _name: ($) => choice($.identifier, $.qualified_name),

    qualified_name: ($) =>
      seq($.identifier, repeat1(seq('.', $.identifier))),

    // tokens

    identifier: (_) => /[A-Za-z_][A-Za-z0-9_]*/,

    boolean_literal: (_) => choice('true', 'false'),

    null_literal: (_) => 'null',

    // Matches what the tokenizer scans, not what the checker accepts: decimal,
    // `0x`, `0o`, `0b`, underscores, a fraction, an exponent. `12abc` lexes as
    // one number here and is reported as a bad number there, which is the same
    // split the compiler makes.
    number_literal: (_) =>
      token(
        /[0-9][0-9a-zA-Z_]*(\.[0-9][0-9a-zA-Z_]*)*([eEpP][-+][0-9a-zA-Z_]*)?/,
      ),

    string_literal: ($) =>
      seq('"', repeat(choice($.escape_sequence, /[^"\\\n]+/)), '"'),

    // The escapes are `\n \t \r \\ \"`. Anything else is scanned the same and
    // reported by the compiler, so a wrong escape does not break the colour of
    // the string around it.
    escape_sequence: (_) => token.immediate(/\\[^\n]/),

    // `//!` documents the file, `///` the declaration below it, `//` and
    // `////` are plain. The three patterns are disjoint, so the longest match
    // picks the right one without a precedence.
    file_doc_comment: (_) => token(/\/\/![^\n]*/),

    doc_comment: (_) => token(choice(/\/\/\/[^\/\n][^\n]*/, /\/\/\//)),

    comment: (_) =>
      token(choice(/\/\/[^!\/\n][^\n]*/, /\/\//, /\/\/\/\/[^\n]*/)),
  },
});

/**
 * @param {RuleOrLiteral} rule
 * @returns {ChoiceRule}
 */
function commaSep(rule) {
  return optional(commaSep1(rule));
}

/**
 * @param {RuleOrLiteral} rule
 * @returns {SeqRule}
 */
function commaSep1(rule) {
  return seq(rule, repeat(seq(',', rule)));
}
