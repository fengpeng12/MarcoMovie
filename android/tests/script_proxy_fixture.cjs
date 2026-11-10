// Self-authored sources only. Each key retains one actual shared runtime instance.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const readline = require('node:readline');
const root = path.join(__dirname, '..', '..');
const sources = new Map();
const python = `from base.spider import Spider as Base
class Spider(Base):
 def init(self, ext): self.count = 0
 def playerContent(self, flag, id, vip): return {'url':self.getProxyUrl({'mode':id,'name':'片 名+%&'})}
 def localProxy(self, params):
  self.count += 1
  mode = params.get('mode', '')
  headers = {'X-Count':str(self.count),'X-Query-OK':str(params.get('name') == '片 名+%&')}
  if mode == 'text': return [200,'application/vnd.apple.mpegurl','#EXTM3U\\n# 名称\\n'+self.getProxyUrl({'mode':'bytes','name':'片 名+%&'})+'\\n',headers]
  if mode == 'range':
   headers['Content-Range'] = 'bytes 1-2/4'
   headers['Content-Length'] = '999'
   headers['X-Range-OK'] = str(params.get('range') == 'bytes=1-2')
   return [206,'application/octet-stream',bytes([255,128]),headers]
  if mode == 'bad-range': return [206,'application/octet-stream',bytes([255,128]),{'Content-Range':'bytes 0-3/4'}]
  if mode == 'bad-total': return [206,'application/octet-stream',bytes([255,128]),{'Content-Range':'bytes 1-2/2'}]
  if mode == 'head-only': return [200,'application/octet-stream','',{'Content-Length':'321'}]
  if mode == 'head-range': return [206,'application/octet-stream','',{'Content-Range':'bytes 1-2/4'}]
  if mode == 'hop': return [200,'text/plain','body',{'Connection':'X-Private','X-Private':'omit','Set-Cookie':'nope=x','Access-Control-Allow-Origin':'*','X-Keep':'keep'}]
  return [200,'application/octet-stream',bytes([0,255,128,65]),headers]
`;
const javascript = `globalThis.__movieSpider={
 count:0,
 play(flag,id){return {url:proxyUrl({mode:id,name:'片 名+%&'})}} ,
 proxy(params){this.count++;let body=[0,255,128,65];
  if(params.mode==='typed')body=new Uint8Array(body);
  if(params.mode==='buffer')body=new Uint8Array(body).buffer;
  if(params.mode==='view')body=new DataView(new Uint8Array([9,...body,8]).buffer,1,4);
  if(params.mode==='flag')return [200,'application/octet-stream',new Uint8Array(body),{},2];
  if(params.mode==='headers')return [200,'application/octet-stream',new Uint8Array(body),false];
  return [200,'application/octet-stream',body,{'X-Count':String(this.count),'X-Query-OK':String(params.name==='片 名+%&')}];}
};`;
function readAsset(folder, file) { return fs.readFileSync(path.join(root, 'android/src/main/assets', folder, file), 'utf8'); }
async function dispatch(command) {
  if (command.op === 'init') {
    const context = vm.createContext({console, setTimeout, clearTimeout, __movieProxyBase:command.base, __proxyAddress:command.base});
    let spider;
    vm.runInContext(command.helpers, context);
    if (command.kind === 'py') {
      for (const file of ['skulpt.min.js','skulpt-stdlib.js','compiled-modules.js','json.js','io.js','spider.js']) {
        vm.runInContext(readAsset('python-host', file), context, {filename:file});
      }
      spider = context.createPythonSpider(python);
      await spider.init('');
    } else {
      vm.runInContext(readAsset('js-host','bootstrap.js'), context);
      vm.runInContext(command.helpers, context);
      vm.runInContext(javascript, context);
      spider = context.__movieSpider;
    }
    sources.set(command.key, {spider, context});
    return true;
  }
  const record = sources.get(command.key);
  if (!record) throw Error('fixture source unavailable');
  const {spider, context} = record;
  if (command.op === 'play') return spider.play('Main', command.mode, []);
  if (command.op === 'proxy') return context.__movieEncodeProxyResult(await spider.proxy(command.params));
  throw Error('unsupported fixture command');
}
let tail = Promise.resolve();
readline.createInterface({input:process.stdin}).on('line', line => {
  tail = tail.then(async () => {
    try { process.stdout.write(JSON.stringify({value:await dispatch(JSON.parse(line))})+'\n'); }
    catch (error) { process.stdout.write(JSON.stringify({error:String(error)})+'\n'); }
  });
});
