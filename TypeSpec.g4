/*
 * TypeSpec.g4 - ANTLR4 Grammar for TabuLua Type Specifications
 *
 * This grammar defines the syntax for type specifications used in TabuLua,
 * a data processing framework for Lua-based games. It enables parsing type
 * definitions in JavaScript, C#, C++, and other ANTLR-supported languages.
 *
 * Usage:
 *   antlr4 TypeSpec.g4                    # Generate Java parser
 *   antlr4 -Dlanguage=CSharp TypeSpec.g4  # Generate C# parser
 *   antlr4 -Dlanguage=Cpp TypeSpec.g4     # Generate C++ parser
 *   antlr4 -Dlanguage=JavaScript TypeSpec.g4  # Generate JS parser
 *
 * The grammar produces a parse tree that can be walked to build an AST
 * with semantic type information (array vs tuple, map vs record, etc.)
 */

grammar TypeSpec;


// ============================================================================
// PARSER RULES
// ============================================================================

/**
 * Entry point - a complete type specification followed by end-of-file.
 * All type specs are ultimately union types (which may contain just one type).
 */
typeSpec
    : unionType EOF
    ;

/**
 * Union type: one or more atomic types separated by '|' (pipe).
 * Represents "one of these types" semantics.
 *
 * Examples:
 *   number|string        - Either a number or string
 *   boolean|number|nil   - Boolean, number, or nil (optional boolean|number)
 *   {string}|{number}    - Array of strings or array of numbers
 *
 * Semantic constraints (not enforced by grammar):
 *   - 'nil' must always be last (represents optional values)
 *   - 'string' should be last or second-to-last (before nil)
 *   - These ordering rules ensure deterministic parsing in Lua
 */
unionType
    : atomicType (PIPE atomicType)*
    ;

/**
 * Atomic type: the building blocks of type expressions.
 * Either a named type reference or a braced type construct.
 */
atomicType
    : typeName      // Named type: string, number, MyModule.MyType
    | bracedType    // Braced construct: {string}, {name:type}, etc.
    ;

/**
 * Type name: simple or dot-separated identifier path.
 * Used for primitive types, custom types, and module-qualified types.
 *
 * Examples:
 *   string              - Primitive string type
 *   integer             - Primitive integer type
 *   MyCustomType        - User-defined type
 *   MyModule.SubType    - Module-qualified type reference
 *
 * Built-in primitive types:
 *   boolean, integer, number, string
 *
 * Integer range types:
 *   ubyte (0-255), ushort (0-65535), uint, byte, short, int, long
 *
 * String extension types:
 *   comment, text, markdown, identifier, name, http,
 *   type_spec, type, version, cmp_version
 *
 * Numeric extension types:
 *   percent, ratio
 *
 * Tagged numeric types:
 *   number_type, tagged_number, quantity
 *
 * Special types:
 *   raw (boolean|number|table|string|nil), nil, true, table
 *
 * Self-referencing field types:
 *   Names matching "self.<field>" (e.g., self._1, self.unit) are parsed
 *   as typeName by this grammar but should be converted to a "selfref"
 *   AST node during semantic analysis. See AST CONSTRUCTION NOTES below.
 */
typeName
    : IDENTIFIER (DOT IDENTIFIER)*
    ;

/**
 * Braced type constructs - the heart of complex type definitions.
 * The semantic meaning depends on the structure of the content.
 *
 * The parse tree uses labeled alternatives (#Name) to distinguish
 * constructs syntactically, but final type determination may require
 * semantic analysis (e.g., distinguishing array from map).
 */
bracedType
    : LBRACE RBRACE                                              # EmptyTable
      // Empty table type: {}
      // Represents any Lua table with no type constraints

    | LBRACE ENUM COLON enumLabels RBRACE                        # EnumType
      // Enumeration type: {enum:label1|label2|...}
      // Examples: {enum:red|green|blue}, {enum:north|south|east|west}
      // Values must be one of the specified string literals

    | LBRACE EXTENDS COMMA typeName RBRACE                       # BareExtendsTuple
      // Bare extends (tuple form): {extends,<type>}
      // Ancestor constraint: values must be names of registered types
      // extending the specified type. E.g., {extends,number} accepts
      // "integer", "float", "kilogram", etc.

    | LBRACE EXTENDS COLON typeName RBRACE                       # BareExtendsRecord
      // Bare extends (record form): {extends:<type>}
      // Same semantics as tuple form; normalized to {extends,<type>}

    | LBRACE EXTENDS COMMA typeName (COMMA unionType)+ RBRACE    # TupleExtends
      // Tuple inheritance: {extends,BaseTuple,additionalType1,additionalType2}
      // Extends an existing tuple type with additional element types
      // The base type must be a previously-defined tuple type

    | LBRACE EXTENDS COLON typeName (COMMA fieldDef)+ RBRACE     # RecordExtends
      // Record inheritance: {extends:BaseRecord,newField:type,...}
      // Extends an existing record type with additional fields
      // The base type must be a previously-defined record type

    | LBRACE bracedItem (COMMA bracedItem)* RBRACE               # BracedContent
      // General braced content - semantic type depends on structure:
      //
      // ARRAY (single type element, no colon):
      //   {string}           - Array of strings
      //   {number}           - Array of numbers
      //   {{string}}         - Array of arrays of strings
      //   {string|nil}       - Array of optional strings
      //
      // MAP (single key:value pair):
      //   {string:number}    - Map from strings to numbers
      //   {identifier:boolean} - Map from identifiers to booleans
      //   {string:{string:number}} - Nested map
      //
      // TUPLE (multiple type elements, no colons):
      //   {string,number}           - Pair of (string, number)
      //   {boolean,string,number}   - Triple
      //   {string,{number}}         - String and array of numbers
      //
      // RECORD (multiple field:type pairs):
      //   {name:string,age:number}     - Record with name and age fields
      //   {id:string,active:boolean}   - Record with id and active fields
      //
      // Semantic rules for disambiguation:
      //   - 1 element without colon = ARRAY
      //   - 1 element with colon = MAP
      //   - 2+ elements without colons = TUPLE
      //   - 2+ elements with colons = RECORD
      //   - Mixed (some with colons, some without) = ERROR
    ;

/**
 * Field definition for record extends.
 * A field name (identifier) followed by its type.
 */
fieldDef
    : IDENTIFIER COLON unionType
    ;

/**
 * An item inside braces - represents either:
 *   - A standalone type (for arrays and tuples)
 *   - A key:value or field:type pair (for maps and records)
 *
 * The optional ':' unionType allows the grammar to parse both forms,
 * with semantic analysis determining the exact construct type.
 *
 * Examples:
 *   string                 - Type element (array or tuple)
 *   string:number          - Pair element (map or record field)
 *   {boolean}:string       - Complex key type in a map
 */
bracedItem
    : unionType (COLON unionType)?
    ;

/**
 * Enumeration labels: one or more identifiers separated by '|'.
 * These are the valid literal values for an enum type.
 *
 * Example: red|green|blue defines three valid values
 */
enumLabels
    : IDENTIFIER (PIPE IDENTIFIER)*
    ;


// ============================================================================
// LEXER RULES
// ============================================================================

/*
 * Keywords
 * These are reserved words with special meaning in type specifications.
 * They cannot be used as field names or type names.
 */

/** Keyword: marks an enumeration type definition */
ENUM
    : 'enum'
    ;

/** Keyword: marks type inheritance (tuple or record) */
EXTENDS
    : 'extends'
    ;

/*
 * Punctuation
 */

/** Left brace: starts braced type constructs */
LBRACE  : '{' ;

/** Right brace: ends braced type constructs */
RBRACE  : '}' ;

/** Colon: separates key:value or field:type pairs */
COLON   : ':' ;

/** Comma: separates elements in tuples, records, and extends */
COMMA   : ',' ;

/** Pipe: separates alternatives in union types and enum labels */
PIPE    : '|' ;

/** Dot: separates parts of qualified type names */
DOT     : '.' ;

/*
 * Identifiers and literals
 */

/**
 * Identifier: standard programming identifier format.
 * Starts with letter or underscore, followed by letters, digits, or underscores.
 *
 * Used for:
 *   - Type names (string, number, MyType)
 *   - Field names in records (name, age, id)
 *   - Enum labels (red, green, blue)
 *   - Module names in qualified paths (MyModule.SubType)
 */
IDENTIFIER
    : [_a-zA-Z][_a-zA-Z0-9]*
    ;

/*
 * Whitespace and comments
 * These are skipped during parsing but can appear anywhere in a type spec.
 */

/** Whitespace: spaces, tabs, newlines are ignored */
WS
    : [ \t\r\n]+ -> skip
    ;

/**
 * Comment: # character to end of line
 * Allows documenting complex type specifications inline.
 *
 * Example:
 *   {
 *     name:string,     # Player's display name
 *     score:integer,   # Current score (0 or higher)
 *     active:boolean   # Whether player is currently in game
 *   }
 */
COMMENT
    : '#' ~[\r\n]* -> skip
    ;


// ============================================================================
// AST CONSTRUCTION NOTES (for parser implementers)
// ============================================================================
/*
 * When building an AST from the parse tree, use these tag conventions
 * to match the Lua implementation:
 *
 * Node structure: { tag: string, value: any }
 *
 * Tag types:
 *   "name"   - Type name reference
 *              value: string (e.g., "string", "MyModule.Type")
 *
 *   "array"  - Array type (homogeneous collection)
 *              value: element type node
 *
 *   "tuple"  - Tuple type (fixed-length, heterogeneous)
 *              value: array of type nodes
 *
 *   "union"  - Union type (one of several types)
 *              value: array of type nodes
 *
 *   "map"    - Map type (key-value dictionary)
 *              value: object with single key-value pair
 *              where key is keyType node, value is valueType node
 *
 *   "record" - Record type (named fields)
 *              value: array of {key: string, value: typeNode} pairs
 *
 *   "table"  - Untyped table (empty braces {})
 *              value: null/nil
 *
 *   "enum"   - Enumeration type
 *              value: array of label strings
 *
 *   "selfref" - Self-referencing field type (dependent type)
 *               value: string (the referenced field name, e.g., "_1", "unit")
 *               Note: The grammar parses "self._1" as a typeName (IDENTIFIER
 *               DOT IDENTIFIER). During semantic analysis, when the first
 *               identifier is "self" and there are exactly two parts, convert
 *               to a selfref node. Self-refs are only valid as field types
 *               inside tuples or records, not as standalone types.
 *
 * Example transformations:
 *
 *   Input: "string"
 *   AST:   { tag: "name", value: "string" }
 *
 *   Input: "{string}"
 *   AST:   { tag: "array", value: { tag: "name", value: "string" } }
 *
 *   Input: "{string:number}"
 *   AST:   { tag: "map", value: {
 *            key: { tag: "name", value: "string" },
 *            value: { tag: "name", value: "number" }
 *          }}
 *
 *   Input: "{string,number}"
 *   AST:   { tag: "tuple", value: [
 *            { tag: "name", value: "string" },
 *            { tag: "name", value: "number" }
 *          ]}
 *
 *   Input: "{name:string,age:number}"
 *   AST:   { tag: "record", value: [
 *            { key: "name", value: { tag: "name", value: "string" } },
 *            { key: "age", value: { tag: "name", value: "number" } }
 *          ]}
 *
 *   Input: "number|string|nil"
 *   AST:   { tag: "union", value: [
 *            { tag: "name", value: "number" },
 *            { tag: "name", value: "string" },
 *            { tag: "name", value: "nil" }
 *          ]}
 *
 *   Input: "{enum:red|green|blue}"
 *   AST:   { tag: "enum", value: ["red", "green", "blue"] }
 *
 *   Input: "{extends,number}"
 *   AST:   { tag: "tuple", value: [
 *            { tag: "name", value: "extends" },
 *            { tag: "name", value: "number" }
 *          ]}
 *   Note: Bare extends produces a 2-element tuple at the AST level.
 *         Semantic analysis distinguishes it from tuple inheritance
 *         (which has 3+ elements) and creates an ancestor constraint
 *         parser instead.
 */
