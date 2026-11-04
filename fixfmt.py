path = 'index.html'
with open(path, 'r', encoding='utf-8') as f:
    c = f.read()
old = 'fmtNum('
new = '((n)=>{n=Number(n||0); if(isNaN(n))n=0; return n.toLocaleString("en-US",{maximumFractionDigits:3});})('
if old in c:
    c2 = c.replace(old, new)
    with open(path, 'w', encoding='utf-8') as f:
        f.write(c2)
    print('done')
else:
    print('no')
