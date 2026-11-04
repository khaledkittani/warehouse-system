with open('index.html','r',encoding='utf-8') as f:
    c = f.read()

new = "((n)=>{n=Number(n||0); return n.toLocaleString('en-US',{maximumFractionDigits:3});})"
c2 = c.replace('fmtNum(', new + '(')
if c2 != c:
    with open('index.html','w',encoding='utf-8') as f:
        f.write(c2)
    print('replaced')
else:
    print('none')
