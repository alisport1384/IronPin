import requests,json,pathlib,concurrent.futures,urllib.parse,datetime,re
from bs4 import BeautifulSoup
p=pathlib.Path('research/iran-channels-v030');registry=json.load(open('assets/registry.json'))
urls={s['url']:s['name'] for s in registry['sources']if s.get('url','').startswith('https://')}
urls.update({'https://novinpars.com/':'نوین پارس مشهد','https://radmanahan.ir/contact-us/':'رادمان آهن مشهد','https://ahan100.com/blog/rebar-price-telegram-channel/':'آهن صد','https://tikahan.com/قیمت-ورق/':'تیک آهن مشهد','https://khoshkamiron.ir/product/میلگرد/':'خوش‌کام مشهد','https://eitaa.com/hayperahan':'هایپر آهن مشهد','https://eitaa.com/fiahan1':'آهن آلات حیدری','https://eitaa.com/samaneahan_com':'سامانه آهن','https://ble.ir/ahaneroz':'آهن روز','https://ble.ir/fiahan':'آهن آلات حیدری','https://rubika.ir/fiahan_com':'آهن آلات حیدری','https://rubika.ir/hayperahan':'هایپر آهن مشهد','https://eitaa.com/radmanahan':'رادمان آهن مشهد','https://rubika.ir/radmanahan':'رادمان آهن مشهد','https://rubika.ir/tikahan':'تیک آهن مشهد'})
# Only follow explicitly published links, never guessed platform handles or APIs.
def get(it):
 u,owner=it;key=__import__('hashlib').sha256(u.encode()).hexdigest()[:16]
 try:
  r=requests.get(u,timeout=13);(p/(key+'.html')).write_text(r.text);s=BeautifulSoup(r.text,'html.parser')
  links=[]
  for a in s.select('a[href]'):
   v=urllib.parse.urljoin(r.url,a['href']);host=urllib.parse.urlparse(v).hostname or ''
   if host in ['eitaa.com','rubika.ir','ble.ir','bale.ai','splus.ir','t.me','telegram.me']:links.append({'url':v,'label':a.get_text(' ',strip=True)[:150]})
  row={'url':u,'owner':owner,'finalUrl':r.url,'http':r.status_code,'title':s.title.get_text(' ',strip=True)if s.title else '', 'file':key+'.html','links':links,'tables':len(s.select('table')),'textSample':s.get_text(' ',strip=True)[:1600],'observedAt':datetime.datetime.now(datetime.timezone.utc).isoformat()};print(owner,r.status_code,len(links),'tables',row['tables'],flush=True);return row
 except Exception as e: print(owner,type(e).__name__,flush=True);return {'url':u,'owner':owner,'error':type(e).__name__}
with concurrent.futures.ThreadPoolExecutor(max_workers=4)as ex:rows=list(ex.map(get,urls.items()))
(p/'discovery.json').write_text(json.dumps(rows,ensure_ascii=False,indent=2))
platform={}
for r in rows:
 for link in r.get('links',[]):
  u=link['url'];host=urllib.parse.urlparse(u).hostname
  if host in ['eitaa.com','rubika.ir','ble.ir','bale.ai','splus.ir'] and not any(x in u for x in ['/share','/share?','/share/']):platform.setdefault(u,{'url':u,'owner':r['owner'],'foundOn':r['url']})
# Verify discovered domestic platform destinations, bounded to 65 published links.
with concurrent.futures.ThreadPoolExecutor(max_workers=4)as ex:verified=list(ex.map(get,[(u,x['owner'])for u,x in list(platform.items())[:65]if u not in urls]))
(p/'verified.json').write_text(json.dumps(verified,ensure_ascii=False,indent=2));(p/'published-links.json').write_text(json.dumps(list(platform.values()),ensure_ascii=False,indent=2))
