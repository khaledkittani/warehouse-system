with open('index.html','r',encoding='utf-8') as f:
    c = f.read()
print('found' if 'fmtNum' in c else 'no')
