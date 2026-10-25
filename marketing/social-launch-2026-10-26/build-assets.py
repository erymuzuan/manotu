from pathlib import Path
from html import escape
import subprocess, os
ROOT=Path(__file__).resolve().parents[2]
OUT=Path(__file__).resolve().parent/'assets'
OUT.mkdir(exist_ok=True)
conf=OUT/'fonts.conf'
conf.write_text(f'<fontconfig><include>/opt/homebrew/etc/fonts/fonts.conf</include><dir>{ROOT}/site/manotu/fonts</dir></fontconfig>')
env=dict(os.environ,FONTCONFIG_FILE=str(conf))

def mark(x,y,w=220,white=False):
    p=ROOT/'docs/brand/manotu'/('manotu-wordmark-white.svg' if white else 'manotu-wordmark.svg')
    s=p.read_text(); start=s.index('>')+1
    return f'<g transform="translate({x},{y}) scale({w/465})">'+s[start:s.rfind('</svg>')]+'</g>'
def text(x,y,s,size=32,color='#0B1B3A',weight=700):
    return f'<text x="{x}" y="{y}" font-family="Nunito, sans-serif" font-size="{size}" font-weight="{weight}" fill="{color}">{escape(s)}</text>'
def line(x,y,s): return text(x,y,s,24,'#0047AB',800)
def save(name,w,h,body):
    svg=f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}"><rect width="100%" height="100%" fill="#F5F7FC"/>{body}</svg>'
    (OUT/f'{name}.svg').write_text(svg)
    subprocess.run(['rsvg-convert',str(OUT/f'{name}.svg'),'-o',str(OUT/f'{name}.png')],env=env,check=True)
# The approved icon, unchanged, with generous safe space for circular profile crops.
icon=(ROOT/'docs/brand/manotu/manotu-icon-square.svg').read_text()
save('profile',1080,1080,'<rect width="1080" height="1080" fill="#0047AB"/><g transform="translate(190,190) scale(3.5)">'+icon[icon.index('>')+1:icon.rfind('</svg>')]+'</g>')
route='<path d="M-60 410 C170 170 370 600 580 300 S900 150 1180 390" fill="none" stroke="#8FB0E8" stroke-width="90" opacity=".35"/><path d="M-60 410 C170 170 370 600 580 300 S900 150 1180 390" fill="none" stroke="#0047AB" stroke-width="14"/><circle cx="580" cy="300" r="27" fill="#FF6B4A" stroke="white" stroke-width="12"/>'
# Facebook cover: primary content centered; lower-left kept clear for profile overlap.
body='<rect width="1640" height="624" fill="#E3ECFA"/><g transform="translate(490,220)">'+route+'</g>'
body+=mark(590,55,300)+text(820,275,'Ma’no tu?',76,weight=900).replace('x="820"','text-anchor="middle" x="820"')
body+=text(820,343,'Ke mana pun, bersama Manotu.',40).replace('x="820"','text-anchor="middle" x="820"')
body+=text(820,407,'Navigasi komuniti Malaysia · Akses awal',26,'#0047AB').replace('x="820"','text-anchor="middle" x="820"')
body+=text(820,471,'manotu.app',30).replace('x="820"','text-anchor="middle" x="820"')
save('facebook-cover',1640,624,body)
posts=[('01-kenalkan','KENALKAN MANOTU',['Ma’no tu?','Jom jalan.'],'Navigasi komuniti untuk Malaysia.','Akses awal · Percuma · Tanpa iklan','route'),('02-rumah-mertua','TEMPAT ANDA',['Rumah Mertua.','Simpan sekali.'],'Label ikut cara anda.','Kegemaran anda kekal dalam telefon.','home'),('03-privasi','PRIVASI ANDA',['Data anda,','milik anda.'],'Rumah. Kerja. Kampung.','Tempat peribadi kekal dalam telefon.','lock'),('04-komuniti','KOMUNITI KITA',['Peta kita.','Bina bersama.'],'Tambah tempat. Bantu orang sampai.','Kongsi tempat awam selepas berhenti.','map')]
for name,kicker,title,sub,footer,kind in posts:
    art='<rect x="64" y="480" width="952" height="360" rx="40" fill="#E3ECFA"/>'
    if kind=='route': art+='<g transform="translate(60,400) scale(.85)">'+route+'</g><path d="M650 595l95 22-70 68 4-53z" fill="#0047AB"/>'
    if kind=='home': art+='<path d="M386 663l154-125 154 125v123H386z" fill="#0047AB"/><path d="M362 664l178-148 178 148" fill="none" stroke="#FF6B4A" stroke-width="20" stroke-linecap="round"/><rect x="512" y="693" width="56" height="93" rx="8" fill="#E3ECFA"/><circle cx="740" cy="579" r="24" fill="#FF6B4A"/>'
    if kind=='lock': art+='<rect x="397" y="622" width="286" height="177" rx="32" fill="#0047AB"/><path d="M450 625v-41a90 90 0 0 1 180 0v41" fill="none" stroke="#0047AB" stroke-width="28"/><circle cx="540" cy="697" r="23" fill="#FF6B4A"/><path d="M540 700v45" stroke="#FF6B4A" stroke-width="18" stroke-linecap="round"/>'
    if kind=='map': art+='<path d="M300 560l160-40 160 65 160-65v240l-160 40-160-65-160 40z" fill="white" stroke="#8FB0E8" stroke-width="5"/><path d="M350 695q90-140 190-40t180-20" fill="none" stroke="#0047AB" stroke-width="15" stroke-linecap="round"/><circle cx="350" cy="695" r="23" fill="#FF6B4A"/><circle cx="720" cy="635" r="23" fill="#FF6B4A"/>'
    body=mark(62,20,210)+line(64,180,kicker)
    for i,t in enumerate(title): body+=text(64,280+i*92,t,84,weight=900)
    body+=text(64,440,sub,32,weight=600)+art+text(64,912,footer,30)+text(64,1000,'MANOTU.APP',25,'#0047AB',900)+text(1016,1000,'AKSES AWAL',22,'#0047AB',800).replace('x="1016"','text-anchor="end" x="1016"')
    save(name,1080,1080,body)
# Instagram story / highlight cover set.
for label,kind in [('Mula','01'),('Privasi','02'),('Cara guna','03'),('Komuniti','04')]:
    save('highlight-'+kind,1080,1080,'<circle cx="540" cy="540" r="370" fill="#E3ECFA"/>'+mark(330,270,420)+text(540,650,label,66).replace('x="540"','text-anchor="middle" x="540"'))
conf.unlink()
