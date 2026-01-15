// Minimal Zig parser for API docgen - extracts pub decls with doc comments (assuming the code is valid)
// 100% hand-written, LLMs still suck at this.
const RE = /\/\/\/ ?(.*)|\/\/! ?(.*)|\/\/ ?(.*)|("[^"]*")|('[^']*')|\b(catch|comptime|const|enum|error|fn|opaque|pub|struct|try|union|var)\b|(@"(?:[^"\\\n]|\\.)*"|@\w+|[a-zA-Z_]\w*)|(\d[\w.]*)|([(){}[\],;:=.?*!<>@&|^~+\-/%])|[ \t\r\n]+|./gy;
const T = ['doc', 'cdoc', '//', 'str', 'ch', 1, 'id', 'num', 1]
const C = ['struct', 'enum', 'union', 'opaque']

function tokenize(s) {
  const tt = [], td = [], ts = [], emit = (t, d, s) => (tt.push(t), td.push(d), ts.push(s))
  for (let m = RE.lastIndex = 0; m = RE.exec(s);) {
    const i = m.findIndex((v, j) => j && v != undefined)
    if (i >= 1) {
      const t = T[i - 1], x = m[i]
      if (t === 'doc' && tt.at(-1) === 'doc') td[td.length - 1] += '\n' + x
      else emit(t === 1 ?x :t, m[i], m.index)
    }
  }
  return [tt, td, ts]
}

function parse(src) {
  const [tt, td, ts] = tokenize(src)
  let i = 0, d = 0, A = [], S = [[-1, A]]

  const adv = () => {
    switch (tt[i++]) {
      case '[': case '(': case '{': d++; break
      case ']': case ')':
      case '}': if (--d === S.at(-1)[0]) { A = S.pop()[1]; } break
    }
  }

  const eat = (sp, cl) => {
    i = sp
    do { adv() } while (!cl.test(tt[i]))
    return src.slice(ts[sp+1], ts[i])
  }

  for (; i < tt.length; adv()) {
    // console.log(d, i, tt[i], td[i])
    switch (tt[i]) {
      case 'const': case 'var': case 'fn':
        if (tt[i-1] !== 'pub' || tt[i+1] !== 'id') break
        const name = td[i+1]
        const doc = tt[i-2] === 'doc' ?td[i-2] :''

        if (tt[i+2] === '=' && C.includes(tt[i+3])) {
          const node = { name, doc, kind: tt[i+=3], children: [] }
          if (tt[i+1] === '(') node.kind += '(' + eat(i+1, /\)/) + ')' // enum(i32), union(my.F(...).E) etc.
          node.body = eat(i + 1, /pub|const|var|fn|}/).trim();
          A.push(node); S.push([d, A]); A = node.children
        }
        
        else if (tt[i+2] === '(') {
          A.push({ name, doc, kind: 'fn', params: eat(i+2, /\)/), ret: eat(i, /\{/) })
        }
    }
  }
  return A
}

export { parse, tokenize };

// CLI support
if (process.argv.length > 2) {
  const { readFileSync } = await import('fs');
  const src = readFileSync(process.argv[2], 'utf-8');
  console.log(JSON.stringify(parse(src), null, 2));
}
