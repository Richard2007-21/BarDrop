import json
T={
"en":{
 "hero":("A shelf at the<br>edge of your screen.","Drop anything at the edge of your screen. Drag it back out whenever you need it."),
 "actions":("Send it<br>anywhere.","Drop items on AirDrop, a folder or the Trash. Folders and the Trash work like in the Finder, and ⌘Z puts things back."),
 "stacks":("Stacks keep<br>things together.","Drop several files at once and they stay together. Click a stack to look inside."),
 "settings":("Feels right<br>at home on a Mac.","Edge, size, actions and how files are kept, in Settings built like macOS. Light and dark."),
},
"de":{
 "hero":("Eine Ablage am Rand<br>deines Bildschirms.","Leg alles am Bildschirmrand ab und zieh es wieder heraus, wenn du es brauchst."),
 "actions":("Schick es<br>überallhin.","Leg Objekte auf AirDrop, einen Ordner oder den Papierkorb. Ordner und Papierkorb funktionieren wie im Finder, ⌘Z legt alles zurück."),
 "stacks":("Stapel halten<br>zusammen.","Mehrere Dateien auf einmal bleiben zusammen. Ein Klick auf den Stapel zeigt, was drin ist."),
 "settings":("Fühlt sich an<br>wie macOS.","Rand, Größe, Aktionen und wie Dateien aufbewahrt werden, in Einstellungen im Stil von macOS. Hell und dunkel."),
}}
HEAD='<html><head><link rel="stylesheet" href="base.css"><style>.shot{position:absolute}.win{position:absolute;width:436px;height:640px;border-radius:16px;overflow:hidden;box-shadow:0 30px 80px rgba(0,0,0,.5);border:1px solid rgba(255,255,255,.14)}.win img{width:436px;height:640px;display:block}.tag{position:absolute;color:#fff;font-size:15px;font-weight:600;opacity:.8}</style></head><body>'
def title(t,top=300,badge=False):
    h,p=t
    b='<div class="badge"><img src="AppIcon.png">BarDrop</div>' if badge else ''
    return f'<div class="title" style="left:110px;top:{top}px">{b}<h1>{h}</h1><p>{p}</p></div>'
for lang,t in T.items():
    pages={}
    pages["hero"]=HEAD+'<div class="wall"></div>'+title(t["hero"],250,True)+f'<img class="shot" src="Produkt_Ablage_{lang}.png" style="right:0;top:200px;width:660px;height:900px;margin-top:-100px">'+'</body></html>'
    # actions: shelf zoomed with bar highlighted by crop
    pages["actions"]=HEAD+'<div class="wall" style="filter:hue-rotate(-25deg)"></div>'+title(t["actions"],310)+f'<img class="shot" src="Produkt_Ablage_{lang}.png" style="right:0;top:100px;width:660px;height:900px"><div style="position:absolute;left:1152px;top:735px;width:440px;height:112px;border-radius:22px;border:2.5px solid rgba(255,255,255,.85);box-shadow:0 0 0 8px rgba(255,255,255,.12),0 0 40px rgba(120,170,255,.6)"></div>'+'</body></html>'
    pages["stacks"]=HEAD+'<div class="wall" style="filter:hue-rotate(30deg)"></div>'+title(t["stacks"],330)+f'<img class="shot" src="Produkt_Stapel_{lang}.png" style="right:0;top:100px;width:660px;height:900px">'+'</body></html>'
    pages["settings"]=HEAD+'<div class="wall" style="filter:hue-rotate(-50deg)"></div>'+title(t["settings"],330)+f'<div class="win" style="left:820px;top:130px;background:#2a2b2e"><img src="Produkt_Objekte_{lang}_dunkel.png"></div><div class="win" style="left:1100px;top:250px;background:#f2f2f4"><img src="Produkt_Oeffnen_{lang}_hell.png"></div>'+'</body></html>'
    for k,v in pages.items():
        open(f"p_{k}_{lang}.html","w").write(v)
