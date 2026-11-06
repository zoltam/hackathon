#!/usr/bin/env python3
"""Render anisotropic Gaussian ellipses with depth sorting and source view-dependent colour.

Desktop inspection helper; not a substitute for iPhone runtime validation.
Supports the current 160-byte degree-3 spherical-harmonic app asset format.
"""
from pathlib import Path
import argparse,json
import moderngl
import numpy as np
from PIL import Image

VS='''#version 330
in vec4 centerAlpha;
in vec4 color;
in vec4 covA;
in vec4 covB;
uniform mat4 vp;
uniform vec2 screen;
out vec2 local;
out vec4 rgba;
void main(){
 vec4 clip=vp*vec4(centerAlpha.xyz,1.0);
 vec2 uv=vec2((gl_VertexID&1)==1?1.0:-1.0,(gl_VertexID&2)==2?1.0:-1.0)*3.0;
 local=uv;rgba=vec4(color.rgb,centerAlpha.w);
 if(clip.w<=0.04){gl_Position=vec4(3,3,3,1);return;}
 vec2 ndc=clip.xy/clip.w;
 vec3 rw=vec3(vp[0].w,vp[1].w,vp[2].w);
 vec3 jx=(vec3(vp[0].x,vp[1].x,vp[2].x)-ndc.x*rw)*(0.5*screen.x/clip.w);
 vec3 jy=(vec3(vp[0].y,vp[1].y,vp[2].y)-ndc.y*rw)*(0.5*screen.y/clip.w);
 mat3 cov=mat3(vec3(covA.x,covA.y,covA.z),vec3(covA.y,covA.w,covB.x),vec3(covA.z,covB.x,covB.y));
 float a=dot(jx,cov*jx)+0.3;float b=dot(jx,cov*jy);float c=dot(jy,cov*jy)+0.3;
 float halfTrace=.5*(a+c);float delta=length(vec2(.5*(a-c),b));
 float l1=halfTrace+delta,l2=max(.25,halfTrace-delta);
 float angle=.5*atan(2*b,a-c);vec2 direction=vec2(cos(angle),sin(angle));
 vec2 offset=direction*(uv.x*min(sqrt(l1),512.0))+vec2(-direction.y,direction.x)*(uv.y*min(sqrt(l2),512.0));
 gl_Position=vec4(clip.xy+2.0*offset*clip.w/screen,clip.z,clip.w);
}'''
FS='''#version 330
in vec2 local;in vec4 rgba;out vec4 frag;
void main(){float r2=dot(local,local);if(r2>9.0)discard;
float a=min(.995,rgba.a*exp(-.5*r2));if(a<.004)discard;
frag=vec4(rgba.rgb*a,a);}
'''

def view_matrix(eye,target,up):
 eye=np.array(eye,dtype=float);forward=np.array(target)-eye;forward/=np.linalg.norm(forward)
 right=np.cross(forward,up);right/=np.linalg.norm(right);vertical=np.cross(right,forward)
 v=np.eye(4);v[:3,:3]=np.stack([right,vertical,-forward]);v[:3,3]=-v[:3,:3]@eye
 return v

def load_scene(assets):
    path = assets / 'boiler-room-sh.splats'
    if path.exists():
        packed = np.memmap(path, dtype=np.uint8, mode='r').reshape(-1, 160)
        data = np.ascontiguousarray(packed[:, :64]).view('<f4').reshape(-1, 16)
        sh = np.ascontiguousarray(packed[:, 64:]).view('<f2').reshape(-1, 48)
        return data, sh
    return np.fromfile(assets / 'boiler-room.splats', '<f4').reshape(-1, 16), None


def scene_colours(data, sh, eye, source_rotation):
    if sh is None:
        return data
    direction = ((data[:, :3] - eye) * [1, -1, -1]) @ np.array(source_rotation).T
    direction /= np.maximum(np.linalg.norm(direction, axis=1, keepdims=True), 1e-8)
    x, y, z = direction.T
    xx, yy, zz = x*x, y*y, z*z
    basis = [
        -.488602512*y, .488602512*z, -.488602512*x,
        1.092548431*x*y, -1.092548431*y*z, .315391565*(3*zz-1),
        -1.092548431*x*z, .546274215*(xx-yy),
        -.590043590*y*(3*xx-yy), 2.890611443*x*y*z, -.457045799*y*(5*zz-1),
        .373176333*z*(5*zz-3), -.457045799*x*(5*zz-1),
        1.445305721*z*(xx-yy), -.590043590*x*(xx-3*yy),
    ]
    result = data.copy()
    colour = result[:, 4:7]
    for i, b in enumerate(basis):
        colour += sh[:, [i, 15+i, 30+i]].astype('f4') * b[:, None]
    result[:, 4:7] = np.clip(colour, 0, 1)
    return result


def render(data,eye,target,out,width=1600,height=1200,ortho=None,cut=None,sh=None,source_rotation=None):
 data=scene_colours(data,sh,eye,np.eye(3) if source_rotation is None else source_rotation)
 ctx=moderngl.create_standalone_context(backend='egl')
 prog=ctx.program(vertex_shader=VS,fragment_shader=FS)
 v=view_matrix(eye,target,[0,0,-1] if ortho else [0,1,0])
 if ortho:
  sx,sy=ortho;near,far=.04,50
  p=np.array([[2/sx,0,0,0],[0,2/sy,0,0],[0,0,-2/(far-near),-(far+near)/(far-near)],[0,0,0,1.]])
 else:
  f=1/np.tan(np.deg2rad(65)/2);near,far=.04,50
  p=np.array([[f/(width/height),0,0,0],[0,f,0,0],[0,0,(far+near)/(near-far),2*far*near/(near-far)],[0,0,-1,0]])
 depth=-(data[:,:3]@v[2,:3]+v[2,3]);mask=depth>.04
 if cut is not None:mask &= data[:,1]<=cut
 idx=np.where(mask)[0];idx=idx[np.argsort(depth[idx])[::-1]]
 buffer=ctx.buffer(data[idx].astype('f4').tobytes())
 vao=ctx.vertex_array(prog,[(buffer,'4f 4f 4f 4f /i','centerAlpha','color','covA','covB')])
 fb=ctx.simple_framebuffer((width,height),components=4);fb.use();fb.clear(.94,.95,.93,1)
 ctx.enable(moderngl.BLEND);ctx.blend_func=(moderngl.ONE,moderngl.ONE_MINUS_SRC_ALPHA)
 prog['vp'].write((p@v).astype('f4').T.tobytes());prog['screen'].value=(width,height)
 vao.render(mode=moderngl.TRIANGLE_STRIP,vertices=4,instances=len(idx));ctx.finish()
 Image.frombytes('RGBA',(width,height),fb.read(components=4)).transpose(Image.Transpose.FLIP_TOP_BOTTOM).convert('RGB').save(out)
 print(out,len(idx),flush=True)
 vao.release();buffer.release();fb.release();ctx.release()

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Capture actual Gaussian scene renders on desktop OpenGL/EGL.')
    parser.add_argument('--assets', type=Path, default=Path('assets/valmet'))
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--camera', type=float, nargs=3)
    parser.add_argument('--target', type=float, nargs=3)
    parser.add_argument('--top-down', action='store_true')
    parser.add_argument('--cut-height', type=float)
    parser.add_argument('--plan-bounds', type=float, nargs=4, metavar=('LEFT', 'BACK', 'RIGHT', 'FRONT'),
                        help='Model-coordinate crop for the overhead illustration only')
    parser.add_argument('--width', type=int, default=1800)
    parser.add_argument('--height', type=int, default=1500)
    args = parser.parse_args()
    if args.width < 16 or args.height < 16:
        parser.error('Image dimensions must be at least 16 pixels')
    site = json.loads((args.assets / 'site.json').read_text())
    data, sh = load_scene(args.assets)
    ortho = None
    if args.top_down:
        if args.plan_bounds:
            left, back, right, front = args.plan_bounds
            if left >= right or back >= front:
                parser.error('Invalid plan bounds')
        else:
            left, back = 0, 0
            right, front = site['width'] * site['cellSize'], site['depth'] * site['cellSize']
        centre = [(left + right) / 2, 0, (back + front) / 2]
        eye = [centre[0], 12, centre[2]]
        span = max(right - left, (front - back) * args.width / args.height)
        ortho = (span, span * args.height / args.width)
        target = centre
    else:
        if args.camera is None or args.target is None:
            parser.error('Provide --camera and --target, or --top-down')
        eye, target = args.camera, args.target
    args.output.parent.mkdir(parents=True, exist_ok=True)
    render(data, eye, target, args.output, args.width, args.height,
           ortho=ortho, cut=args.cut_height, sh=sh,
           source_rotation=site.get('shRotation'))
