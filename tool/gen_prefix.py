import re, json
fa2en = str.maketrans('۰۱۲۳۴۵۶۷۸۹٠١٢٣٤٥٦٧٨٩', '01234567890123456789')
txt = open('/tmp/wiki_codes.txt', encoding='utf-8').read().split('\n')
def norm(s): return s.replace('ي','ی').replace('ك','ک').replace('\u200c',' ').strip()
names = {norm(c['name']) for c in json.load(open('/home/user/IronPin/assets/cities.json'))}
sections = {'051': (116, 179), '031': (179, 234)}
out = {}
for area, (a, b) in sections.items():
    table = {}
    for line in txt[a:b]:
        if not line.startswith('| ') or '||' not in line: continue
        left, right = line[2:].split('||', 1)
        name = re.sub(r'\[\[(?:[^\]|]*\|)?([^\]]*)\]\]', r'\1', left).strip()
        name = re.sub(r'^شهرستان\s+', '', name)
        codes = re.findall(r'\d+', right.translate(fa2en))
        for c in codes: table.setdefault(c, []).append(name)
    out[area] = table
json.dump(out, open('prefix.json', 'w'), ensure_ascii=False, indent=0)
for area, table in out.items():
    uniq = {c: v[0] for c, v in table.items() if len(v) == 1}
    amb = {c: v for c, v in table.items() if len(v) > 1}
    counties = sorted(set(uniq.values()))
    print(area, 'unique', len(uniq), 'ambiguous', len(amb))
    print(' not city names:', [c for c in counties if norm(c) not in names])
    print(' amb:', amb)
