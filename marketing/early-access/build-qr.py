"""Generate a deterministic website QR card; requires qrcode[pil] and zxing-cpp."""
from pathlib import Path
import json,re,zipfile
import qrcode,zxingcpp
from PIL import Image, ImageDraw, ImageFont
root=Path(__file__).resolve().parent
url='https://manotu.app/'
qr=qrcode.QRCode(error_correction=qrcode.constants.ERROR_CORRECT_Q,box_size=18,border=4)
qr.add_data(url);qr.make(fit=True)
im=qr.make_image(fill_color='#0B1B3A',back_color='white').convert('RGB')
im.save(root/'images/08-website-qr.png')
card=Image.new('RGB',(1080,1350),'#E3ECFA');d=ImageDraw.Draw(card)
fontpath=root.parents[1]/'site/manotu/fonts/nunito-variable.ttf'
def line(y,text,size,color='#0B1B3A'):
 f=ImageFont.truetype(str(fontpath),size);d.text((540,y),text,font=f,fill=color,anchor='mt')
line(65,'Manotu',90);line(190,'Jom cuba. Bantu kami perbaiki.',42)
card.paste(im,((1080-im.width)//2,305))
line(1040,'manotu.app',66);line(1150,'Imbas untuk laman rasmi',35)
line(1210,'Percuma · Tanpa iklan',34)
card.save(root/'images/09-website-qr-card.png')
for name in ['08-website-qr.png','09-website-qr-card.png']:
 decoded=zxingcpp.read_barcode(Image.open(root/'images'/name));assert decoded and decoded.text==url,name
 print(name,'verified:',decoded.text)
p=root/'first-wave-posts.json';posts=json.loads(p.read_text())
for post in posts:
 post['website_url']=url;post['qr_image']='images/09-website-qr-card.png'
 post['caption']=post['caption'].replace('Android: https://manotu.app/download/','Laman rasmi: https://manotu.app/\nAndroid: https://manotu.app/download/')
p.write_text(json.dumps(posts,ensure_ascii=False,indent=2))
p=root/'first-wave-posts.md';s=p.read_text();s=s.replace('Android: https://manotu.app/download/','Laman rasmi: https://manotu.app/\nAndroid: https://manotu.app/download/');s+='\n## QR code and clickable links\n\nAttach images/09-website-qr-card.png as an additional image with each post. The QR encodes https://manotu.app/ directly, with no tracking or redirect service. Keep the website URL in the caption for people reading on their own phone. PNG images themselves cannot contain tappable hyperlinks. Instagram feed caption URLs are not tappable; use the profile website link or a Story link sticker.\n\n![Scan to open Manotu website](images/09-website-qr-card.png)\n';p.write_text(s)
p=root/'first-wave.html';s=p.read_text();s=s.replace('</style>','.qrpanel{display:flex;gap:24px;align-items:center;background:white;padding:24px;border-radius:20px;margin:24px 0}.qrpanel img{width:180px}.cta{display:inline-block;background:#0047ab;color:white;padding:12px 20px;border-radius:12px;text-decoration:none;margin:8px 8px 8px 0}@media(max-width:600px){.qrpanel{flex-direction:column}}</style>')
block='<section class="qrpanel"><a href="https://manotu.app/" target="_blank" rel="noopener"><img src="images/08-website-qr.png" alt="QR code opening https://manotu.app/"></a><div><h2>Imbas atau tekan pautan</h2><p>Scan from another phone, or tap a link on this phone.</p><a class="cta" href="https://manotu.app/">Buka manotu.app</a><a class="cta" href="https://manotu.app/download/">Muat turun Android</a><p><a href="images/09-website-qr-card.png" download>Download QR companion image</a></p></div></section>'
s=s.replace('<section class="post">',block+'<section class="post">',1)
s=s.replace('Android: https://manotu.app/download/','Laman rasmi: https://manotu.app/\nAndroid: https://manotu.app/download/')
s=re.sub(r'(?<!["=])https://manotu\.app/download/', '<a href="https://manotu.app/download/">https://manotu.app/download/</a>',s) if False else s
# Keep caption text intact for copy button; add real clickable actions outside each caption.
s=s.replace('</pre></div></section>','</pre><a class="cta" href="https://manotu.app/">Website</a><a class="cta" href="https://manotu.app/download/">Android download</a><p>Second attachment: <a href="images/09-website-qr-card.png" download>website QR card</a></p></div></section>')
p.write_text(s)
files=['first-wave.html','first-wave-posts.md','first-wave-posts.json','channel-shortlist.md','image-prompts-first-wave.md','build-qr.py',*sorted(set(x['image'] for x in posts)),'images/08-website-qr.png','images/09-website-qr-card.png']
with zipfile.ZipFile(root/'manotu-first-wave.zip','w',zipfile.ZIP_DEFLATED) as z:
 for name in files:z.write(root/name,name)
