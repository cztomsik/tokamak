// Minimal Zig parser for the purpose of generating API documentation
// by Kamil Tomsik (cztomsik)
const RE = /\/\/\/ ?(.*)|\/\/! ?(.*)|\/\/ ?(.*)|("(?:[^"\\]|\\.)*")|('(?:[^'\\]|\\.)*')|\b(catch|comptime|const|enum|error|fn|inline|opaque|pub|struct|test|try|union|var)\b|(@"(?:[^"\\\n]|\\.)*"|@\w+|[a-zA-Z_]\w*)|(\d[\w.]*)|([(){}[\],;:=.?*!<>@&|^~+\-/%])|[ \t\r\n]+|./gy
const T = ['doc', 'cdoc', '//', 'str', 'ch', 1, 'id', 'num', 1]
const C = ['struct', 'enum', 'union', 'opaque']

function tokenize(s) {
  const toks = []
  for (let m, doc = '', d = RE.lastIndex = 0; m = RE.exec(s);) {
    const i = m.findIndex((v, j) => j && v != undefined)
    if (i < 0 || i === 3) continue
    const t = T[i - 1], k = t === 1 ?m[i] :t
    if (t === 'doc') { doc += m[i] + '\n'; continue }
    else (toks.push([m.index, k, m[i], d, doc]), doc = '')
    if (k === '[' || k === '(' || k === '{') d++
    if (k === ']' || k === ')' || k === '}') d--
  }
  return toks
}

function parse(src) {
  const toks = tokenize(src);
  let r // shared & re-used

  const t = k => i => toks[i]?.[1] === k && [i + 1, toks[i][2]]
  const any = i => i < toks.length && [i + 1, toks[i][1]]
  const any_of = ks => i => ks.includes(toks[i]?.[1]) && [i + 1, toks[i][1]]
  const not = p => i => !p(i) && [i + 1, toks[i][1]]
  const or = (...ps) => i => ps.reduce((r, p) => r || p(i), null)
  const opt = p => i => p(i) || [i, null]
  const map = (p, f) => i => (r = p(i)) && [r[0], f(r[1], i)]
  const txt = p => i => (r = p(i)) && [r[0], src.slice(toks[i][0], toks[r[0]]?.[0]).trim()]
  const seq = (...ps) => (i, a = []) => ps.every((p) => (r = p(i)) && ((i = r[0]), a.push(r[1]))) && [i, a]
  const skip_until = p => (i, d = toks[i][3]) => {
    while (i < toks.length && !((r = p(i)) && toks[i]?.[3] === d)) i++
    return [i, null]
  }
  const rep = (min, max, p, sep = null) => (i, arr = []) => {
    while (arr.length < max && (r = p(i))) {
      (i = r[0]), arr.push(r[1])
      if (sep) if (r = sep(i)) i = r[0]; else break
    }
    return arr.length >= min && [i, arr]
  }

  const warn = i => i < toks.length && toks[i][1] !== '}' && [i+1, console.log('unmatched', toks[i], JSON.stringify(src.substr(toks[i][0], 32)))]
  const id = t('id')
  
  const skip_fn = txt(seq(t('fn'), id, t('('), skip_until(t('}')), t('}')))
  const fret = txt(rep(1, 99, not(t('{'))))
  const fparams = txt(skip_until(t(')')))
  const fbody = txt(skip_until(t('}')))
  const pub_fn = seq(t('pub'), opt(t('inline')), t('fn'), id, t('('), fparams, t(')'), fret, t('{'), fbody, t('}'))
  const api_fn = map(pub_fn, ([,,,name,,params,,ret], i) => ({ kind: 'fn', name, params, ret, doc: toks[i][4] }))

  const skip_decl = txt(seq(any_of(['const', 'var']), id, skip_until(t(';')), t(';')))
  const skip_test = txt(seq(t('test'), opt(or(id, t('str'))), t('{'), skip_until(t('}')), t('}')))
  const skip_comptime = txt(seq(t('comptime'), t('{'), skip_until(t('}')), t('}')))
  const cparams = opt(txt(seq(t('('), skip_until(t(')')), t(')'))))
  const cfield = txt(seq(id, opt(seq(t(':'), skip_until(t(',')))))) // TODO: or }?
  const cfields = rep(0, 99, cfield, t(','))
  const container = seq(any_of(C), cparams, t('{'), cfields, i => items(i), t('}'))
  const pub_const = seq(t('pub'), t('const'), id, t('='), container, t(';'))
  const api_type = map(pub_const, ([,,name,,[kind,params,,fields,children]], i) => ({ kind, params, name, fields, doc: toks[i][4], children }))
  const api_export = seq(t('pub'), skip_decl) // TODO: { kind: "export" } + update build_docs

  const item = or(api_fn, skip_fn, api_type, api_export, skip_decl, skip_test, skip_comptime, warn) // TODO: generics (pub fn(...) type)
  const items = map(rep(0, 999, item), rs => rs.filter(r => r?.kind))

  return (r = items(0)) && r[1]
}

export { parse, tokenize };

// CLI support
if (process.argv.length > 2) {
  const { readFileSync } = await import('fs');
  const src = readFileSync(process.argv[2], 'utf-8');
  console.log(JSON.stringify(parse(src), null, 2));
}
