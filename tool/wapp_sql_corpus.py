"""tool/wapp_sql_corpus.py OUT.json SRC.c... (run from ../apps; writes
test/fixtures/wapp_sql_corpus.json for wapp_db_sql_corpus_test): preprocess each wapp C file (macros
resolved) and collect the SQL string-literal argument of every db_exec /
db_query call (adjacent literals concatenated). Calls whose SQL is not a pure
literal are skipped and counted."""
import json, re, subprocess, sys, os
out, srcs = sys.argv[1], sys.argv[2:]
lit = re.compile(r'"((?:[^"\\]|\\.)*)"')
stmts, skipped = [], 0
for src in srcs:
    d = os.path.dirname(src)
    pp = subprocess.run(['clang-19', '-E', '-P', '-w', '-I', d,
        '-I', os.path.join(d, '..', 'hal'), '-I', os.path.join(d, '..', 'sdk'),
        '-D__wasm__', src], capture_output=True, text=True)
    text = pp.stdout
    if pp.returncode != 0:
        print('cpp failed', src, pp.stderr[:300], file=sys.stderr)
    for m in re.finditer(r'\bdb_(exec|query)\s*\(', text):
        i = m.end()
        # skip first argument (handle) up to the first top-level comma
        depth = 0
        while i < len(text):
            c = text[i]
            if c in '([': depth += 1
            elif c in ')]':
                if depth == 0: break
                depth -= 1
            elif c == ',' and depth == 0: break
            i += 1
        if i >= len(text) or text[i] != ',': continue
        i += 1
        parts = []
        while True:
            while i < len(text) and text[i].isspace(): i += 1
            mm = lit.match(text, i)
            if not mm: break
            parts.append(mm.group(1)); i = mm.end()
        while i < len(text) and text[i].isspace(): i += 1
        if not parts or i >= len(text) or text[i] not in ',)':
            skipped += 1; continue
        sql = bytes(''.join(parts), 'utf-8').decode('unicode_escape')
        stmts.append({'file': os.path.relpath(src, os.path.dirname(os.path.dirname(src))), 'sql': sql})
seen, uniq = set(), []
for s in stmts:
    if s['sql'] not in seen: seen.add(s['sql']); uniq.append(s)
json.dump(uniq, open(out, 'w'), indent=1, ensure_ascii=False)
print(len(uniq), 'statements;', skipped, 'non-literal calls skipped')
