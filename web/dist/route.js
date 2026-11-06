const inside = ([x, y], polygon) => {
  let result = false;
  for (let i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
    const [ax, ay] = polygon[i], [bx, by] = polygon[j];
    if ((ay > y) !== (by > y) && x < (bx - ax) * (y - ay) / (by - ay) + ax) result = !result;
  }
  return result;
};

export function shortestRoute(scene, aspect, clearance = 1) {
  if (!scene.start || !scene.end || scene.floor.length < 3) return null;
  const height = 80, width = Math.max(12, Math.min(220, Math.round(height * aspect)));
  const size = width * height;
  const center = (i) => [(i % width + .5) / width, (Math.floor(i / width) + .5) / height];
  const cell = ([x, y]) => Math.min(width - 1, Math.floor(x * width)) +
    Math.min(height - 1, Math.floor(y * height)) * width;
  const walkable = (p) => inside(p, scene.floor) && !scene.obstacles.some(o => inside(p, o));
  const open = new Uint8Array(size);
  for (let i = 0; i < size; i++) {
    const [x, y] = center(i);
    open[i] = [[0,0],[-1,0],[1,0],[0,-1],[0,1],[-1,-1],[1,1],[-1,1],[1,-1]]
      .every(([dx,dy]) => walkable([x + dx * clearance / width, y + dy * clearance / height]));
  }
  const start = cell(scene.start), end = cell(scene.end);
  if (!open[start] || !open[end] || !walkable(scene.start) || !walkable(scene.end)) return [];
  const cost = new Float64Array(size).fill(Infinity);
  const prev = new Int32Array(size).fill(-1);
  const closed = new Uint8Array(size);
  const queue = [start];
  const score = new Float64Array(size);
  const [endX, endY] = center(end);
  const dxCost = aspect / width, dyCost = 1 / height;
  cost[start] = 0;
  while (queue.length) {
    let best = 0;
    for (let i = 1; i < queue.length; i++) if (score[queue[i]] < score[queue[best]]) best = i;
    const at = queue[best];
    queue[best] = queue.at(-1);
    queue.pop();
    if (closed[at]) continue;
    if (at === end) {
      const path = [scene.end];
      for (let i = end; i !== -1; i = prev[i]) path.push(center(i));
      path.push(scene.start);
      return path.reverse();
    }
    closed[at] = 1;
    const x = at % width, y = Math.floor(at / width);
    for (let dy = -1; dy <= 1; dy++) for (let dx = -1; dx <= 1; dx++) {
      if ((!dx && !dy) || x + dx < 0 || x + dx >= width || y + dy < 0 || y + dy >= height) continue;
      const next = at + dx + dy * width;
      if (!open[next] || closed[next] || (dx && dy && (!open[at + dx] || !open[at + dy * width]))) continue;
      const nextCost = cost[at] + Math.hypot(dx * dxCost, dy * dyCost);
      if (nextCost >= cost[next]) continue;
      cost[next] = nextCost;
      const [nx, ny] = center(next);
      score[next] = nextCost + Math.hypot((nx - endX) * aspect, ny - endY);
      prev[next] = at;
      queue.push(next);
    }
  }
  return [];
}
