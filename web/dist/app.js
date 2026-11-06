import {shortestRoute} from './route.js';

const $ = id => document.getElementById(id);
const video = $('video'), canvas = $('overlay'), ctx = canvas.getContext('2d');
const tools = [...document.querySelectorAll('[data-tool]')];
const empty = (time = 0) => ({time, floor: [], obstacles: [], start: null, end: null, target: null});
const sample = {
  ...empty(),
  floor: [[.03,.19],[.96,.19],[.96,.94],[.03,.94]],
  obstacles: [
    [[.375,.176],[.517,.176],[.517,.69],[.375,.69]],
    [[.729,.269],[.891,.269],[.891,.45],[.729,.45]],
    [[.081,.269],[.16,.269],[.16,.343],[.081,.343]]
  ],
  start: [.14,.42], end: [.8,.51], target: [[.81,.36],[.884,.36]],
};
const hints = {
  floor: 'Merkitse kulkualueen reunat ja sulje monikulmio.',
  obstacle: 'Merkitse esteen reunat ja sulje monikulmio.',
  start: 'Valitse lähtöpiste kulkualueella.',
  end: 'Valitse vapaa huoltopaikka laitteen vierestä.',
  target: 'Valitse laitteen keskipiste ja sitten ympyrän reuna.',
};

let scenes = [empty()], scene = scenes[0], tool = 'floor', draft = [], history = [];
let routes = new WeakMap(), videoUrl, ready = false, exporting = false, audioContext, audioSource;
let name = '', steps = '';
const aspect = () => video.videoWidth / video.videoHeight || 16 / 9;
const at = time => scenes.findLast(item => item.time <= time + .005) ?? scenes[0];
const stamp = time => time.toFixed(1) + ' s';

function routeFor(item) {
  if (!routes.has(item)) routes.set(item, shortestRoute(item, aspect()));
  return routes.get(item);
}

function draw(context, width, height, item, editing) {
  const scale = Math.max(1, height / 500);
  const pos = ([x,y]) => [x * width, y * height];
  const path = (points, stroke, fill, thickness = 2, close = true) => {
    if (!points.length) return;
    context.beginPath();
    context.moveTo(...pos(points[0]));
    for (const point of points.slice(1)) context.lineTo(...pos(point));
    if (close) context.closePath();
    if (fill) { context.fillStyle = fill; context.fill(); }
    context.strokeStyle = stroke;
    context.lineWidth = thickness * scale;
    context.lineJoin = 'round';
    context.lineCap = 'round';
    context.stroke();
  };
  if (editing) {
    path(item.floor, '#8fead2', '#49e2b51c');
    item.obstacles.forEach(points => path(points, '#ff8a7e', '#ff55494a'));
    path(draft, '#fff6aa', null, 2, false);
    draft.forEach(point => dot(point, '#fff6aa'));
  }
  function dot(point, color) {
    if (!point) return;
    context.beginPath();
    context.arc(...pos(point), 5 * scale, 0, Math.PI * 2);
    context.fillStyle = color;
    context.fill();
    context.strokeStyle = '#122524';
    context.lineWidth = 2 * scale;
    context.stroke();
  }
  const route = routeFor(item);
  if (route?.length) {
    path(route, '#102421', null, 8, false);
    path(route, '#70f0cd', null, 4, false);
    for (let i = 7; i < route.length - 1; i += 10) {
      const [x,y] = pos(route[i]), [px,py] = pos(route[i - 1]);
      const angle = Math.atan2(y - py, x - px);
      const side = sign => [(x - 8*scale*Math.cos(angle + sign*.65))/width,(y - 8*scale*Math.sin(angle + sign*.65))/height];
      path([side(-1),route[i],side(1)], '#fff', null, 2, false);
    }
  }
  dot(item.start, '#fff');
  dot(item.end, '#70f0cd');
  if (item.target) {
    const [center, edge] = item.target;
    const [x,y] = pos(center), [ex,ey] = pos(edge);
    context.beginPath();
    context.arc(x,y,Math.max(5, Math.hypot(ex-x,ey-y)),0,2*Math.PI);
    context.fillStyle = '#ffb74744';
    context.fill();
    context.lineWidth = 4 * scale;
    context.strokeStyle = '#ffbd5f';
    context.stroke();
    if (name) caption(name, x, Math.max(22 * scale, y - 12 * scale));
  }
  function caption(label, x, y) {
    context.font = `${14 * scale}px system-ui`;
    const maxWidth = width * .82;
    const box = Math.min(maxWidth, context.measureText(label).width + 14 * scale);
    const left = Math.max(0, Math.min(x - box / 2, width - box));
    context.fillStyle = '#122524ed';
    context.fillRect(left,y - 17 * scale,box,23 * scale);
    context.fillStyle = '#fff';
    context.fillText(label,left + 7 * scale,y,maxWidth - 14 * scale);
  }
  if (!editing && steps.trim()) {
    const lines = steps.split('\n').map(s => s.trim()).filter(Boolean);
    lines.slice(0,5).forEach((line,i) => caption(`${i+1}. ${line}`, width/2, height - (Math.min(5, lines.length) - i)*25*scale));
  }
}

function render() {
  const rect = canvas.getBoundingClientRect();
  const width = Math.round(rect.width * devicePixelRatio);
  const height = Math.round(rect.height * devicePixelRatio);
  if (canvas.width !== width || canvas.height !== height) { canvas.width = width; canvas.height = height; }
  ctx.clearRect(0,0,width,height);
  if (ready) draw(ctx,width,height,scene,video.paused && !exporting);
}
new ResizeObserver(render).observe(canvas);

function refresh() {
  const route = ready ? routeFor(scene) : null;
  $('status').textContent = !ready ? 'Avaa oma video tai kokeile esimerkkiä.'
    : exporting ? 'Video viedään toistamalla se alusta loppuun.'
    : route?.length === 0 ? 'Reittiä ei löytynyt. Tarkista kulkualue, esteet ja pisteiden väli esteisiin.'
    : route ? (draft.length ? hints[tool] : 'Lyhin reitti merkityssä kulkualueessa.')
    : hints[tool];
  $('play').textContent = video.paused ? 'Toista' : 'Pysäytä';
  $('play').disabled = !ready || exporting;
  $('time').disabled = !ready || exporting;
  $('save').disabled = !ready || exporting;
  $('export').disabled = !ready || exporting || !window.MediaRecorder || !canvas.captureStream;
  $('newScene').disabled = !ready || !video.paused || exporting;
  $('removeScene').disabled = !ready || scene === scenes[0] || exporting || !video.paused;
  $('finish').disabled = draft.length < 3 || !['floor','obstacle'].includes(tool) || !video.paused || exporting;
  $('undo').disabled = !video.paused || exporting || (!draft.length && !history.length);
  $('sceneList').disabled = !ready || exporting;
  tools.forEach(button => {
    button.disabled = !ready || !video.paused || exporting;
    button.setAttribute('aria-pressed', button.dataset.tool === tool);
  });
  canvas.classList.toggle('playing', !video.paused || exporting);
  for (const id of ['file','demo','load','name','steps']) $(id).disabled = exporting;
  render();
}
function listScenes() {
  $('sceneList').replaceChildren(...scenes.map(item => new Option(stamp(item.time),String(item.time),false,item === scene)));
}
function selectAtTime() {
  const item = at(video.currentTime);
  if (item !== scene) {
    scene = item; draft = []; history = [];
    $('sceneList').value = String(item.time);
  }
  $('time').value = video.currentTime;
  $('clock').textContent = stamp(video.currentTime);
  refresh();
}
function reset(items, label, instructions) {
  scenes = items; scene = items[0]; draft = []; history = [];
  routes = new WeakMap(); tool = 'floor';
  name = $('name').value = label;
  steps = $('steps').value = instructions;
  updateInstructions();
  listScenes();
  refresh();
}
function open(url, demo = false) {
  video.pause();
  ready = false;
  if (videoUrl) URL.revokeObjectURL(videoUrl);
  videoUrl = demo ? null : url;
  reset(demo ? [structuredClone(sample)] : [empty()],demo ? 'Demopumppu P-02' : '',
    demo ? 'Tunnista kohde tunnisteesta P-02.\nNoudata paikan hyväksyttyä erotusohjetta ennen avaamista.\nAvaa laitteen hyväksytty huolto-ohje ennen korjausta.' : '');
  video.src = url;
  video.load();
}
$('file').onchange = event => {
  const file = event.target.files[0];
  if (file) open(URL.createObjectURL(file));
  event.target.value = '';
};
$('demo').onclick = () => open('./demo.mp4',true);
video.onloadedmetadata = () => {
  ready = Number.isFinite(video.duration) && video.duration > 0;
  $('time').max = ready ? video.duration : 0;
  routes = new WeakMap();
  selectAtTime();
};
video.onerror = () => { ready = false; refresh(); $('status').textContent = 'Videota ei voitu avata. Kokeile selaimesi tukemaa MP4- tai WebM-tiedostoa.'; };
video.ontimeupdate = video.onseeked = selectAtTime;
video.onpause = video.onplay = refresh;
$('time').oninput = () => { video.pause(); video.currentTime = Number($('time').value); };
$('play').onclick = async () => {
  if (!video.paused) return video.pause();
  if (video.ended) video.currentTime = 0;
  try { await audioContext?.resume(); await video.play(); }
  catch { $('status').textContent = 'Videon toisto ei onnistunut.'; }
};
$('sceneList').onchange = () => { video.pause(); video.currentTime = Number($('sceneList').value); selectAtTime(); };
$('newScene').onclick = () => {
  const time = Math.round(video.currentTime * 100) / 100;
  if (scenes.some(item => Math.abs(item.time - time) < .05)) return;
  scene = empty(time);
  scenes.push(scene); scenes.sort((a,b) => a.time - b.time);
  draft = []; history = []; tool = 'floor';
  listScenes(); refresh();
};
$('removeScene').onclick = () => {
  scenes = scenes.filter(item => item !== scene); selectAtTime(); listScenes();
};
tools.forEach(button => button.onclick = () => { tool = button.dataset.tool; draft = []; refresh(); });
function change(callback) {
  history.push(structuredClone(scene));
  callback(); routes.delete(scene); refresh();
}
canvas.onclick = event => {
  if (!ready || !video.paused || exporting) return;
  const {left,top,width,height} = canvas.getBoundingClientRect();
  const point = [(event.clientX-left)/width,(event.clientY-top)/height].map(v => Math.max(0,Math.min(1,v)));
  if (tool === 'start' || tool === 'end') return change(() => scene[tool] = point);
  draft.push(point);
  if (tool === 'target' && draft.length === 2) change(() => { scene.target = draft; draft = []; });
  else refresh();
};
$('finish').onclick = () => change(() => {
  if (tool === 'floor') scene.floor = draft;
  else scene.obstacles.push(draft);
  draft = [];
});
$('undo').onclick = () => {
  if (draft.length) draft.pop();
  else if (history.length) Object.assign(scene, history.pop());
  routes.delete(scene); refresh();
};
function updateInstructions() {
  $('instructions').replaceChildren(...steps.split('\n').map(line => line.trim()).filter(Boolean).map(line => {
    const li = document.createElement('li'); li.textContent = line; return li;
  }));
  render();
}
$('name').oninput = () => { name = $('name').value; render(); };
$('steps').oninput = () => { steps = $('steps').value; updateInstructions(); };
function download(blob, filename) {
  const url = URL.createObjectURL(blob), link = document.createElement('a');
  link.href = url; link.download = filename; link.click();
  setTimeout(() => URL.revokeObjectURL(url), 30_000);
}
$('save').onclick = () => download(new Blob([JSON.stringify({version:1, scenes, name, steps})],{type:'application/json'}),'huoltoreitti.json');
const isPoint = p => Array.isArray(p) && p.length === 2 && p.every(v => Number.isFinite(v) && v >= 0 && v <= 1);
const isPolygon = p => Array.isArray(p) && p.length >= 3 && p.length <= 150 && p.every(isPoint);
$('load').onchange = async event => {
  const file = event.target.files[0]; event.target.value = '';
  if (!file) return;
  try {
    if (!ready) throw new Error('Avaa ensin video, johon merkinnät kuuluvat.');
    if (file.size > 1_000_000) throw new Error('Merkintätiedosto on liian suuri.');
    const project = JSON.parse(await file.text());
    if (project.version !== 1 || !Array.isArray(project.scenes) ||
        !project.scenes.length || project.scenes.length > 150 || project.scenes[0]?.time !== 0 ||
        !project.scenes.every((s,i) => s && Number.isFinite(s.time) && s.time <= video.duration &&
          (!i || s.time > project.scenes[i-1].time) && (isPolygon(s.floor) || Array.isArray(s.floor) && !s.floor.length) &&
          Array.isArray(s.obstacles) && s.obstacles.length <= 60 && s.obstacles.every(isPolygon) &&
          (s.start === null || isPoint(s.start)) && (s.end === null || isPoint(s.end)) &&
          (s.target === null || Array.isArray(s.target) && s.target.length === 2 && s.target.every(isPoint)))) {
      throw new Error('Merkinnät ovat virheellisiä tai eivät sovi tähän videoon.');
    }
    video.pause(); video.currentTime = 0;
    reset(project.scenes, String(project.name ?? '').slice(0,100), String(project.steps ?? '').slice(0,6000));
  } catch (error) { $('status').textContent = error.message; }
};
$('export').onclick = async () => {
  let stream, recorder, timer, destination;
  const priorTime = video.currentTime;
  try {
    video.pause();
    exporting = true; refresh();
    const frame = document.createElement('canvas');
    const ratio = Math.min(1,1280 / Math.max(video.videoWidth,video.videoHeight));
    frame.width = Math.round(video.videoWidth * ratio); frame.height = Math.round(video.videoHeight * ratio);
    const out = frame.getContext('2d');
    const drawFrame = () => {
      out.drawImage(video,0,0,frame.width,frame.height);
      draw(out,frame.width,frame.height,at(video.currentTime),false);
    };
    stream = frame.captureStream(30);
    if (!audioContext) {
      audioContext = new AudioContext();
      audioSource = audioContext.createMediaElementSource(video);
      audioSource.connect(audioContext.destination);
    }
    await audioContext.resume();
    destination = audioContext.createMediaStreamDestination();
    audioSource.connect(destination);
    destination.stream.getAudioTracks().forEach(track => stream.addTrack(track));
    const mimeType = ['video/webm;codecs=vp8,opus','video/mp4','video/webm'].find(type => MediaRecorder.isTypeSupported(type));
    recorder = new MediaRecorder(stream, mimeType ? {mimeType} : {});
    const chunks = [];
    recorder.ondataavailable = ({data}) => { if (data.size) chunks.push(data); };
    const recorded = new Promise((resolve,reject) => {
      recorder.onstop = resolve;
      recorder.onerror = event => reject(event.error);
    });
    if (video.currentTime !== 0) {
      const seeked = new Promise(resolve => video.addEventListener('seeked',resolve,{once:true}));
      video.currentTime = 0;
      await seeked;
    }
    drawFrame();
    const ended = new Promise(resolve => video.addEventListener('ended',resolve,{once:true}));
    recorder.start();
    timer = setInterval(drawFrame,1000/30);
    await video.play();
    await Promise.race([ended,recorded]);
    if (recorder.state !== 'inactive') recorder.stop();
    await recorded;
    if (!chunks.length) throw new Error('Tallennin ei tuottanut videota.');
    const type = recorder.mimeType || 'video/webm';
    download(new Blob(chunks,{type}), 'huoltoreitti.' + (type.includes('mp4') ? 'mp4' : 'webm'));
  } catch (error) {
    alert('Videon vienti epäonnistui. ' + error.message);
  } finally {
    clearInterval(timer); video.pause();
    if (recorder && recorder.state !== 'inactive') recorder.stop();
    stream?.getTracks().forEach(track => track.stop());
    if (destination) audioSource.disconnect(destination);
    video.currentTime = priorTime; exporting = false; refresh();
  }
};
refresh();
