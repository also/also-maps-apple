const fs=require('fs'),vm=require('vm'),path=require('path');
const sharp=require('sharp');
const root=path.resolve(__dirname, '../..');
const source=fs.readFileSync(path.join(__dirname, 'splash-source.js'),'utf8');
let d='',shapes=[];
const ctx={setTransform(){},clearRect(){},beginPath(){d='';},moveTo(x,y){d+=`M${x} ${y}`;},lineTo(x,y){d+=`L${x} ${y}`;},closePath(){d+='Z';},fill(){shapes.push(`<path d="${d}" fill="${this.fillStyle}"/>`);},stroke(){shapes.push(`<path d="${d}" fill="none" stroke="${this.strokeStyle}" stroke-width="${this.lineWidth}" stroke-linejoin="round"/>`);}};
const canvas={getContext:()=>ctx,getBoundingClientRect:()=>({width:620,height:330}),width:620,height:330};
vm.runInNewContext(source,{URLSearchParams,location:{search:''},document:{documentElement:{classList:{toggle(){}}},querySelector:()=>canvas,addEventListener(){}},window:{devicePixelRatio:1},matchMedia:()=>({matches:true,addEventListener(){}}),getComputedStyle:()=>({color:'#303a31',getPropertyValue:()=> '#dce1d5'}),ResizeObserver:class{observe(){}},cancelAnimationFrame(){}});
const info={author:'xcode',version:1}; const brand=root+'/SourcesTV/Assets.xcassets/AppIcon.brandassets';
const manifest=JSON.parse(fs.readFileSync(brand+'/Contents.json'));
manifest.assets=manifest.assets.filter(asset=>!['top-shelf-image','top-shelf-image-wide'].includes(asset.role));
(async()=>{for(const [name,width,role] of [['Top Shelf Image',1920,'top-shelf-image'],['Top Shelf Image Wide',2320,'top-shelf-image-wide']]){
const svg=`<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="720" viewBox="0 0 ${width} 720"><path fill="#f3f0e8" d="M0 0H${width}V720H0Z"/><g transform="translate(${width/2-403} 80) scale(1.3)">${shapes.join('')}<text x="310" y="390" text-anchor="middle" font-family="Georgia, Times New Roman, serif" font-size="52" letter-spacing="-2.34" fill="#303a31">maps.also.dev</text></g></svg>`;
const dir=brand+'/'+name+'.imageset';fs.mkdirSync(dir,{recursive:true});
for(const scale of [1,2]) await sharp(Buffer.from(svg)).resize(width*scale,720*scale).flatten({background:'#f3f0e8'}).png().toFile(dir+`/image@${scale}x.png`);
fs.writeFileSync(dir+'/Contents.json',JSON.stringify({info,images:[1,2].map(scale=>({idiom:'tv',scale:`${scale}x`,filename:`image@${scale}x.png`}))},null,2)+'\n');
manifest.assets.push({filename:name+'.imageset',idiom:'tv',role,size:`${width}x720`});
if(width===2320)fs.writeFileSync(root+'/docs/branding/top-shelf.svg',svg);
}
fs.writeFileSync(brand+'/Contents.json',JSON.stringify(manifest,null,2)+'\n');})().catch(error => { console.error(error); process.exitCode = 1; });
