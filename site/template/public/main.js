const zig = (hljs) => ({
  name: 'Zig',
  keywords: {
    keyword:
      'addrspace align allowzero and anyframe anytype asm break callconv catch comptime const ' +
      'continue defer else enum errdefer error export extern fn for if inline linksection ' +
      'noalias noinline nosuspend opaque or orelse packed pub resume return struct suspend ' +
      'switch test threadlocal try union unreachable var volatile while',
    type:
      'bool void noreturn type anyerror anyopaque comptime_int comptime_float isize usize ' +
      'f16 f32 f64 f80 f128 c_char c_short c_ushort c_int c_uint c_long c_ulong c_longlong ' +
      'c_ulonglong c_longdouble',
    literal: 'true false null undefined',
  },
  contains: [
    hljs.C_LINE_COMMENT_MODE,
    { className: 'string', begin: /\\\\/, end: /$/ },
    hljs.QUOTE_STRING_MODE,
    { className: 'string', begin: /'(?:[^'\\]|\\.)+'/ },
    { className: 'built_in', begin: /@[A-Za-z_]\w*/ },
    { className: 'type', begin: /\b[iu]\d+\b/ },
    {
      className: 'number',
      begin: /\b(?:0x[\da-fA-F_]+|0o[0-7_]+|0b[01_]+|\d[\d_]*(?:\.[\d_]+)?(?:[eE][+-]?\d+)?)\b/,
    },
    {
      beginKeywords: 'fn',
      end: /\(/,
      excludeEnd: true,
      contains: [{ className: 'title.function', begin: /[A-Za-z_]\w*/ }],
    },
  ],
})

export default {
  configureHljs: (hljs) => hljs.registerLanguage('zig', zig),
}
