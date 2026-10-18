// Zweites Vorschau-GIF: drei Fotos als Stapel ablegen, eines auf eine Folie ziehen, eine Notiz
// in den Papierkorb und alles wieder zurück. Am Ende ist alles exakt wie am Anfang (Loop).
const C=(x)=>Math.max(0,Math.min(1,x)), lerp=(a,b,t)=>a+(b-a)*t;
const io=(t)=>t<.5?4*t*t*t:1-Math.pow(-2*t+2,3)/2;
const out=(t)=>1-Math.pow(1-t,3);
const back=(t)=>{const c1=1.2,c3=c1+1;return 1+c3*Math.pow(t-1,3)+c1*Math.pow(t-1,2)};
const seg=(t,a,b)=>C((t-a)/(b-a));
const $=(id)=>document.getElementById(id);
function path(t,keys){
  if(t<=keys[0][0])return keys[0].slice(1,3);
  for(let i=1;i<keys.length;i++){if(t<=keys[i][0]){const[a,x0,y0]=keys[i-1],[b,x1,y1,arc=0]=keys[i];const u=io(C((t-a)/(b-a)));
    const bow=Math.sin(u*Math.PI)*arc;return[lerp(x0,x1,u),lerp(y0,y1,u)-bow]}}
  return keys[keys.length-1].slice(1,3)}

// Ablage: Aufnahme 440×600 pt (doppelt gerendert), gezeigt 374×510 ab (506,30)
const SX=374/880, OX=506, OY=30;
const at=(x,y)=>[OX+x*SX, OY+y*SX];          // Pixel der Aufnahme → Seite
const BODY_LEFT=at(280,0)[0];
const SLOT=window.SLOTS;                      // gemessen, siehe unten
const ICON={d1:[72,118],d2:[72,206],d3:[72,294]};
const PH=[505,223];                           // Bildfeld auf der Folie
const DUR=16.5;

const P=[[0,430,470],[0.5,430,470],[0.9,30,80,20],[1.8,118,338],[2.0,118,338],[2.25,74,206,10],[2.35,74,206],
  [3.55,858,290,40],[3.8,858,290],[4.35,SLOT.s1[0],SLOT.s1[1]+2,15],[4.6,SLOT.s1[0],SLOT.s1[1]+2],
  [4.8,SLOT.s2[0],SLOT.s2[1]+2,8],[4.9,SLOT.s2[0],SLOT.s2[1]+2],[6.15,PH[0],PH[1],30],[6.45,PH[0],PH[1]],
  [7.2,872,285,25],[7.95,SLOT.notes[0],SLOT.notes[1]+2,20],[8.45,SLOT.notes[0],SLOT.notes[1]+2],[9.25,SLOT.trash[0],SLOT.trash[1],15],[9.5,SLOT.trash[0],SLOT.trash[1]],
  [10.6,720,330,15],[11.0,SLOT.s1[0],SLOT.s1[1]+2,10],[11.5,SLOT.s1[0],SLOT.s1[1]+2],[12.3,700,340,10],
  [12.6,600,336],[13.3,420,330,20],[14.4,420,330],[15.1,140,440,25],[15.4,140,440],[16.2,430,470,15],[16.5,430,470]];

// Zeitpunkt, an dem der Zeiger beim Herausziehen die Ablage verlässt: sie schließt sofort
let LEAVE=5.5; for(let t=4.9;t<6.2;t+=1/120){if(path(t,P)[0]<BODY_LEFT){LEAVE=t;break}}

function shelfImage(t){
  if(t<3.6) return 'g0d';
  if(t<4.5) return 'g1';
  if(t<4.85) return 'g2';
  if(t<7) return 'g2s';
  if(t<8.4) return 'g4';
  if(t<9.0) return 'g4n';
  if(t<9.3) return 'g4t';
  if(t<9.9) return 'g5';
  if(t<11.3) return 'g4';
  if(t<12.0) return 'g6';
  return 'g0';
}
function openness(t){
  // Ziehen vom Schreibtisch: öffnet, sobald die Fotos nah genug am Rand sind
  if(t>=3.2&&t<LEAVE) return back(seg(t,3.2,3.48));
  if(t>=LEAVE&&t<LEAVE+0.3) return 1-io(seg(t,LEAVE,LEAVE+0.22));
  // Zeiger am Rand: Streifen, nach der Wartezeit offen
  if(t>=7.55&&t<12.9) return back(seg(t,7.55,7.83));
  if(t>=12.9&&t<13.2) return 1-io(seg(t,12.9,13.12));
  return 0;
}
function strip(t){
  if(t>=2.4&&t<3.4) return seg(t,2.4,2.55)*(1-seg(t,3.25,3.4));
  if(t>=7.22&&t<7.75) return seg(t,7.22,7.32)*(1-seg(t,7.6,7.75));
  return 0;
}
function keys(t){
  const k=[[9.6,10.3,['⌘','Z']],[11.05,11.6,['⌘']],[11.75,12.25,['⌫']],[13.75,14.35,['⌘','Z']]];
  for(const [a,b,v] of k){ if(t>=a-0.12&&t<b+0.12) return [v, seg(t,a-0.12,a)*(1-seg(t,b,b+0.12))]; }
  return [[],0];
}
let lastKeys='';
// Ruhiger ablaufen lassen: alles etwas langsamer, und nach jedem wichtigen Schritt kurz innehalten
const SLOW=1.3;
const HOLDS=[[1.85,0.6],[3.75,0.9],[4.55,0.6],[6.45,1.0],[7.9,0.5],[9.45,0.9],[10.35,0.8],[11.35,0.4],[12.3,0.8],[14.4,0.9],[15.4,0.5]];
function sceneTime(real){
  let r=real, s=0, last=0;
  for(const [at,hold] of HOLDS){
    const span=(at-last)*SLOW;
    if(r<span) return last+r/SLOW;
    r-=span;
    if(r<hold) return at;
    r-=hold; last=at;
  }
  return Math.min(DUR,last+r/SLOW);
}
const REAL=DUR*SLOW+HOLDS.reduce((a,h)=>a+h[1],0);
window.render=function(real){
  real=((real%REAL)+REAL)%REAL;
  let t=sceneTime(real);
  const [px,py]=path(t,P);
  const pt=$('pointer'); pt.style.left=(px-2)+'px'; pt.style.top=(py-2)+'px';

  // Lasso auf dem Schreibtisch
  const la=$('lasso');
  if(t>=0.9&&t<1.85){const [x0,y0]=[30,80]; la.style.display='block';
    la.style.left=Math.min(x0,px)+'px'; la.style.top=Math.min(y0,py)+'px';
    la.style.width=Math.abs(px-x0)+'px'; la.style.height=Math.abs(py-y0)+'px';} else la.style.display='none';
  // Markierung: blau solange der Finder vorn ist, grau wenn die Präsentation vorn ist
  const finderFront = t<13.45 || t>=15.3;
  for(const id of ['d1','d2','d3']){
    const el=$(id); const y=ICON[id][1];
    let sel = (t>=0.9&&t<1.85) ? (py>y-14) : (t>=1.85&&t<15.3);
    el.classList.toggle('sel', sel&&finderFront); el.classList.toggle('dim', sel&&!finderFront);
  }
  $('app').textContent = finderFront ? 'Finder' : 'Present';
  $('m4').textContent = finderFront ? 'Go' : 'Insert';
  $('win').classList.toggle('inactive', finderFront);

  // Gezogenes: drei Fotos vom Schreibtisch, ein Foto aus dem Stapel, die Notiz
  const g=$('ghost'); let html='', go=0, gx=px, gy=py;
  if(t>=2.35&&t<3.75){
    let u=0; if(t>=3.6) u=out(seg(t,3.6,3.75));
    const tx=lerp(px,SLOT.s1[0],u), ty=lerp(py,SLOT.s1[1],u), sc=lerp(1,.6,u);
    go=.8*(1-seg(t,3.66,3.75));
    for(const [id,n] of [['d1',1],['d2',2],['d3',3]]){
      const dx=(ICON[id][0]-ICON.d2[0])*(1-u), dy=(ICON[id][1]-ICON.d2[1])*(1-u);
      html+=`<div style="position:absolute;left:${dx-25*sc}px;top:${dy-19*sc}px;width:${50*sc}px;height:${37.5*sc}px;background:url(GIF2_Sunset_${n}.jpg) center/cover;box-shadow:0 2px 6px rgba(0,0,0,.4)"></div>`;
    }
    html+=`<div style="position:absolute;left:${20*sc}px;top:${-28*sc}px;min-width:18px;height:18px;border-radius:9px;background:#ff3b30;color:#fff;font-size:11px;font-weight:700;display:flex;align-items:center;justify-content:center;padding:0 5px;opacity:${1-u}">3</div>`;
    gx=tx; gy=ty;
  } else if(t>=4.9&&t<6.35){
    let u=0; if(t>=6.2) u=out(seg(t,6.2,6.35));
    go=.85*(1-seg(t,6.25,6.35));
    const sc=lerp(1,2.2,u);
    html=`<div style="position:absolute;left:${-27*sc}px;top:${-20*sc}px;width:${54*sc}px;height:${40*sc}px;background:url(GIF2_Sunset_2.jpg) center/cover;border-radius:3px;box-shadow:0 3px 8px rgba(0,0,0,.45)"></div>`+
      (u<0.01?`<div style="position:absolute;left:-36px;top:24px;width:72px;text-align:center"><span style="font-size:10.5px;font-weight:600;color:#fff;background:#2f6ff5;padding:1px 5px;border-radius:4px;white-space:nowrap">Sunset 2.jpg</span></div>`:'');
    gx=lerp(px,PH[0],u); gy=lerp(py,PH[1],u);
  } else if(t>=8.5&&t<9.38){
    let u=0; if(t>=9.3) u=out(seg(t,9.3,9.38));
    go=.85*(1-u);
    html=`<img src="GIF2_notes_icon.png" style="position:absolute;left:-27px;top:-27px;width:54px;height:54px;transform:scale(${1-u*.6})">`+
      (u<0.01?`<div style="position:absolute;left:-40px;top:30px;width:80px;text-align:center"><span style="font-size:10.5px;font-weight:600;color:#fff;background:#2f6ff5;padding:1px 5px;border-radius:4px;white-space:nowrap">Notes.txt</span></div>`:'');
  }
  g.innerHTML=html; g.style.opacity=go; g.style.left=gx+'px'; g.style.top=gy+'px';

  // Ablage
  const o=Math.max(0,openness(t)), sh=$('shelf');
  sh.style.opacity=C(o*2.2); sh.style.transform=`scale(${lerp(.04,1,o)},${lerp(.16,1,o)})`;
  sh.style.filter=`blur(${(1-C(o))*6}px)`;
  const img=shelfImage(t);
  for(const el of sh.querySelectorAll('img')) el.style.opacity = el.id===img ? 1 : 0;
  // Herausgezogenes bleibt an seinem Platz blass, solange die Ablage es zeigt
  const dim=$('dim'); let dimAt=null;
  // Die gezogene Kachel bleibt in der Ablage sichtbar, bis das Ziel sie übernimmt
  if(dimAt){dim.style.opacity=o; dim.style.left=(dimAt[0]-29)+'px'; dim.style.top=(dimAt[1]-23)+'px'} else dim.style.opacity=0;
  const s=$('strip'), st=strip(t); s.style.opacity=st; s.style.width=(6*st)+'px';

  // Folie: Bild nach dem Ablegen, ⌘Z in der Präsentation nimmt es wieder weg
  let ph=0; if(t>=6.25&&t<14.0) ph=seg(t,6.25,6.4)*(1-seg(t,14.0,14.12));
  $('photo').style.opacity=ph; $('thph').style.opacity=ph;
  $('ph').classList.toggle('hot', t>=5.85&&t<6.25);
  $('ph').style.opacity=1-ph;

  const [kv,ko]=keys(t); const ks=$('keys'); const kk=kv.join('|');
  if(kk!==lastKeys){ks.innerHTML=kv.map(k=>`<span>${k}</span>`).join(''); lastKeys=kk;}
  ks.style.opacity=ko;
  // Klicks: kurzes Eindrücken des Zeigers
  const clicks=[2.3,4.45,4.85,8.45,11.3,13.4,15.3];
  let press=0; for(const c of clicks) if(t>=c&&t<c+0.12) press=1;
  pt.style.transform=`scale(${press?0.88:1})`;
};
window.DURATION=REAL;
render(0);
