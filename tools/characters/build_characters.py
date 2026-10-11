"""PS1-style passengers and monsters for Late Night Taxi.

Run headless:  python build_characters.py <out_dir>
(needs the `bpy` module, Blender 4.x/5.x). Writes:
  People.fbx    male (M_) and female (F_) rigid R15 bodies, coat skirts, hats, wrist cast
  Monsters.fbx  road-crossing figure (RF_), Runner (RN_), Mutant long-arm body (MU_)
  Textures.fbx  one small plane per texture variant (Tex_<name>) so a single
                Import 3D uploads every face and outfit texture
  tex/*.png     the textures themselves (painted at 64/128 px, upscaled 4x nearest)
  CharacterKitData.lua  joint/part data for ReplicatedStorage.CharacterKit

Local frame while building: r = character's right, u = up, f = front (metres).
Blender: x = -r, y = -f, z = u (character faces -Y). Sized so a seated rider
matches the player's own R15 avatar (about 5.3 studs tall), not the spec's 8.2.
"""
import math, os, random, sys, json
import bpy, bmesh
from PIL import Image

OUT = sys.argv[-1] if len(sys.argv) > 1 and not sys.argv[-1].endswith('.py') else 'out'
TEX = os.path.join(OUT, 'tex')
os.makedirs(TEX, exist_ok=True)
K = (5.3 / 1.78) / 2.8          # blender units per metre (cab imports at 2.8 studs/BU)
random.seed(7)

# ---------------------------------------------------------------- textures
BODY_REG = {  # x0, y0, x1, y1 in a 128x128 outfit atlas
    'UT': (0, 0, 64, 40), 'LT': (64, 0, 128, 20), 'SK': (64, 20, 128, 48),
    'UA': (0, 40, 32, 72), 'LA': (32, 40, 64, 72), 'UL': (64, 48, 96, 96),
    'LL': (96, 48, 128, 96), 'FT': (0, 72, 32, 96), 'HAT': (0, 96, 64, 128),
    'CAST': (64, 96, 80, 112),
}
FACE_REG = {'HD': (0, 0, 64, 48), 'HN': (0, 48, 64, 64)}  # 64x64 face/skin texture


def shade(c, f):
    return tuple(max(0, min(255, int(v * f))) for v in c)


def fill(px, reg, col, top=1.08, bot=0.72, noise=7):
    x0, y0, x1, y1 = reg
    for y in range(y0, y1):
        f = top + (bot - top) * (y - y0) / max(1, y1 - y0 - 1)
        for x in range(x0, x1):
            n = random.randint(-noise, noise)
            px[x, y] = tuple(max(0, min(255, int(v * f) + n)) for v in col)


def put(px, x, y, col, reg=None):
    if reg:
        x, y = reg[0] + x, reg[1] + y
    px[x % 128 if reg is None else x, y] = col


def col_line(px, reg, fx, col, w=1, y_from=0.0, y_to=1.0):
    """vertical stripe at fraction fx of the region width (0.25 = front)."""
    x0, y0, x1, y1 = reg
    cx = x0 + int(fx * (x1 - x0))
    for y in range(y0 + int(y_from * (y1 - y0)), y0 + int(y_to * (y1 - y0))):
        for dx in range(w):
            px[min(x1 - 1, cx + dx - w // 2), y] = col


def row_band(px, reg, fy0, fy1, col):
    x0, y0, x1, y1 = reg
    for y in range(y0 + int(fy0 * (y1 - y0)), y0 + max(int(fy0 * (y1 - y0)) + 1, int(fy1 * (y1 - y0)))):
        for x in range(x0, x1):
            px[x, y] = shade(col, 1 + random.uniform(-.05, .05))


def paint_outfit(name, o):
    img = Image.new('RGB', (128, 128), (40, 40, 40))
    px = img.load()
    top, bot = o['top'], o['bottom']
    fill(px, BODY_REG['UT'], top)
    fill(px, BODY_REG['UA'], o.get('sleeve', top))
    fill(px, BODY_REG['LA'], o.get('sleeve', top))
    fill(px, BODY_REG['LT'], o.get('waist', bot))
    fill(px, BODY_REG['UL'], bot)
    fill(px, BODY_REG['LL'], o.get('shin', bot))
    fill(px, BODY_REG['FT'], o.get('shoes', (30, 28, 26)), 1.0, .6)
    fill(px, BODY_REG['SK'], o.get('skirt', top))
    hat = o.get('hat', (50, 50, 55))
    fill(px, BODY_REG['HAT'], hat)
    fill(px, BODY_REG['CAST'], (225, 222, 210), 1, .85, 3)
    if 'under' in o:   # shirt/undershirt showing at the open front of a jacket
        col_line(px, BODY_REG['UT'], .25, o['under'], 5, 0.0, 1.0)
    if 'zip' in o:
        col_line(px, BODY_REG['UT'], .25, o['zip'], 1)
        col_line(px, BODY_REG['SK'], .25, o['zip'], 1)
    if 'buttons' in o:
        reg = BODY_REG['UT']
        for fy in (.3, .5, .7, .9):
            put(px, int(.25 * 64) + 2, int(fy * 40), o['buttons'], reg)
        reg = BODY_REG['SK']
        for fy in (.15, .45):
            put(px, int(.25 * 64) + 2, int(fy * 28), o['buttons'], reg)
    if 'collar' in o:
        row_band(px, BODY_REG['UT'], 0, .12, o['collar'])
    if 'tie' in o:
        col_line(px, BODY_REG['UT'], .25, o['tie'], 2, .1, .75)
    if 'belt' in o:
        row_band(px, BODY_REG['LT'], 0, .25, o['belt'])
    if 'stripe' in o:  # hi-vis bands
        row_band(px, BODY_REG['UT'], .55, .68, o['stripe'])
        row_band(px, BODY_REG['LL'], .3, .38, o['stripe'])
    if 'cuff' in o:
        row_band(px, BODY_REG['LA'], .85, 1, o['cuff'])
    if 'lanyard' in o:
        reg = BODY_REG['UT']
        for i in range(10):
            put(px, 12 + i // 2, i * 2, o['lanyard'], reg)
            put(px, 20 - i // 2, i * 2, o['lanyard'], reg)
        for dx in range(3):
            for dy in range(4):
                put(px, 15 + dx, 20 + dy, (220, 220, 210), reg)
    if 'apron' in o:
        col_line(px, BODY_REG['LT'], .25, o['apron'], 14)
        col_line(px, BODY_REG['UL'], .25, o['apron'], 10)
    if 'ribs' in o:
        reg = BODY_REG['UT']
        for ry in range(10, 34, 4):
            for x in range(6, 26):
                put(px, x, ry, shade(top, .7), reg)
    if 'tatters' in o:
        for reg in (BODY_REG['UL'], BODY_REG['LL'], BODY_REG['SK']):
            x0, y0, x1, y1 = reg
            for x in range(x0, x1):
                for y in range(y1 - random.randint(0, 6), y1):
                    px[x, y] = shade(o['tatters'], random.uniform(.6, 1))
    if o.get('wet'):
        for _ in range(140):
            x, y = random.randrange(128), random.randrange(96)
            for d in range(random.randint(2, 6)):
                if y + d < 128:
                    px[x, y + d] = shade(px[x, y + d], .65)
    path = os.path.join(TEX, name + '.png')
    img.resize((512, 512), Image.NEAREST).save(path)
    return path


def paint_face(name, f):
    img = Image.new('RGB', (64, 64))
    px = img.load()
    skin, hair = f['skin'], f.get('hair', (45, 35, 28))
    fill(px, FACE_REG['HD'], skin, 1.08, .8, 4)
    fill(px, FACE_REG['HN'], skin, 1.05, .8, 4)
    long_hair = f.get('long', False)
    bald = f.get('bald', False)
    # hair: crown rows, back of head, sides
    for x in range(64):
        back = abs(((x - 48 + 32) % 64) - 32)   # 0 at back centre (x=48)
        front = abs(((x - 16 + 32) % 64) - 32)  # 0 at face centre (x=16)
        if bald:
            depth = 3
        elif front < 9:
            depth = 9 if not f.get('fringe') else 13
        elif back < 14:
            depth = 40 if long_hair else 22
        else:
            depth = 30 if long_hair else 16
        for y in range(depth):
            px[x, y] = shade(hair, 1.05 - y * .01 + random.uniform(-.08, .08))
    if f.get('faceless'):
        for y in range(12, 34):
            for x in range(10, 23):
                px[x, y] = shade(skin, 0.95 + random.uniform(-.03, .03))
    else:
        eye_y = 16
        white = f.get('eyewhite', (215, 212, 200))
        pupil = f.get('pupil', (25, 22, 20))
        brow = f.get('brow', shade(hair, .8))
        for ex in (12, 19):
            if not f.get('noeyes'):
                px[ex, eye_y] = white
                px[ex + 1, eye_y] = pupil if not f.get('nopupils') else white
                if f.get('blackeyes'):
                    px[ex, eye_y] = px[ex + 1, eye_y] = (5, 5, 8)
                    px[ex, eye_y + 1] = shade(skin, .5)
            else:
                px[ex, eye_y] = px[ex + 1, eye_y] = shade(skin, .55)
            px[ex, eye_y - 2] = px[ex + 1, eye_y - 2] = brow
            px[ex, eye_y + 1] = shade(skin, f.get('undereye', .88))
            px[ex + 1, eye_y + 1] = shade(skin, f.get('undereye', .88))
        for y in range(17, 23):            # nose shadow
            px[17, y] = shade(skin, .82)
        px[16, 22] = px[17, 22] = shade(skin, .7)
        lip = f.get('lips', shade(skin, .7))
        m = f.get('mouth', 'line')
        if m == 'line':
            for x in range(14, 20):
                px[x, 26] = lip
        elif m == 'smile':
            for x in range(11, 23):
                px[x, 26] = (240, 238, 225) if 12 < x < 21 else lip
            px[11, 25] = px[22, 25] = lip
            px[10, 24] = px[23, 24] = lip
            for x in range(12, 22):
                px[x, 27] = lip
        elif m == 'gape':
            for y in range(25, 31):
                for x in range(13, 21):
                    px[x, y] = (12, 6, 6)
        elif m == 'maw':     # Runner: mouth wrapped round the face
            for y in range(23, 30):
                for x in range(5, 28):
                    px[x, y] = (10, 4, 4)
            for x in range(5, 28, 2):
                px[x, 23] = px[x + 1, 29] = (200, 196, 170)
        if f.get('beard'):
            for y in range(25, 33):
                for x in range(10, 24):
                    if random.random() < .55:
                        px[x, y] = shade(hair, .9)
        if f.get('lipstick'):
            for x in range(14, 20):
                px[x, 26] = f['lipstick']
    if f.get('wet'):
        for _ in range(40):
            x, y = random.randrange(64), random.randrange(40)
            for d in range(random.randint(2, 5)):
                if y + d < 48:
                    px[x, y + d] = shade(px[x, y + d], .75)
    path = os.path.join(TEX, name + '.png')
    img.resize((256, 256), Image.NEAREST).save(path)
    return path


# ---------------------------------------------------------------- meshes
def ring(center, a1, a2, rad1, rad2, n, phase=0.0, bump=None):
    pts = []
    for i in range(n):
        t = 2 * math.pi * i / n + phase
        c, s = math.cos(t), math.sin(t)
        p = [center[k] + a1[k] * rad1 * c + a2[k] * rad2 * s for k in range(3)]
        if bump and i == n // 4:                 # push the front vertex (nose, toe)
            p = [p[k] + a2[k] * bump for k in range(3)]
        pts.append(p)
    return pts


def to_blender(p):
    return (-p[0] * K, -p[2] * K, p[1] * K)


def loft(name, rings_spec, n, region, atlas, axis='u', cap0=True, cap1=True):
    """rings_spec: list of (center(r,u,f), rad1, rad2[, bump]). axis 'u' lofts
    upward (radii along r and f), 'f' lofts forward (radii along r and u)."""
    if axis == 'u':
        a1, a2, hk = (1, 0, 0), (0, 0, 1), 1
    else:
        a1, a2, hk = (1, 0, 0), (0, 1, 0), 2
    rings = [ring(rs[0], a1, a2, rs[1], rs[2], n, bump=rs[3] if len(rs) > 3 else None) for rs in rings_spec]
    hs = [rs[0][hk] for rs in rings_spec]
    hmin, hmax = min(hs), max(hs)
    W, H = atlas
    x0, y0, x1, y1 = region
    bm = bmesh.new()
    uv = bm.loops.layers.uv.new('UVMap')
    verts = [[bm.verts.new(to_blender(p)) for p in r] for r in rings]

    def uvp(i, j):
        t = (hs[j] - hmin) / max(1e-6, hmax - hmin)
        if axis == 'f':
            t = 1 - t
        px_ = x0 + (i / n) * (x1 - x0)
        py_ = y0 + (1 - t) * (y1 - y0 - 0.01)
        return (px_ / W, 1 - py_ / H)

    for j in range(len(rings) - 1):
        for i in range(n):
            i2 = (i + 1) % n
            vs = [verts[j][i], verts[j][i2], verts[j + 1][i2], verts[j + 1][i]]
            if axis == 'u':
                vs = vs[::-1]
            face = bm.faces.new(vs)
            uvs = [uvp(i, j), uvp(i + 1, j), uvp(i + 1, j + 1), uvp(i, j + 1)]
            if axis == 'u':
                uvs = uvs[::-1]
            for loop, c in zip(face.loops, uvs):
                loop[uv].uv = c
    for cap, j, flip in ((cap0, 0, axis != 'u'), (cap1, len(rings) - 1, axis == 'u')):
        if not cap:
            continue
        vs = verts[j] if flip else verts[j][::-1]
        face = bm.faces.new(vs)
        c = uvp(1, j)
        cy = c[1] + (0.01 if j else -0.01) * 0
        for loop in face.loops:
            loop[uv].uv = (c[0] + random.uniform(0, .05) * (x1 - x0) / W, cy)
    bmesh.ops.triangulate(bm, faces=bm.faces[:])
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    for p in me.polygons:
        p.use_smooth = False
    ob = bpy.data.objects.new(name, me)
    bpy.context.collection.objects.link(ob)
    return ob


def mat_for(path):
    name = os.path.splitext(os.path.basename(path))[0]
    if name in bpy.data.materials:
        return bpy.data.materials[name]
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    bsdf = nt.nodes.get('Principled BSDF')
    bsdf.inputs['Roughness'].default_value = 1.0
    tex = nt.nodes.new('ShaderNodeTexImage')
    tex.image = bpy.data.images.load(path)
    tex.interpolation = 'Closest'
    nt.links.new(tex.outputs['Color'], bsdf.inputs['Base Color'])
    return m


def assign(ob, path):
    ob.data.materials.clear()
    ob.data.materials.append(mat_for(path))


def bbox_center_L(ob):
    vs = [v.co for v in ob.data.vertices]
    mn = [min(v[i] for v in vs) for i in range(3)]
    mx = [max(v[i] for v in vs) for i in range(3)]
    c = [(mn[i] + mx[i]) / 2 for i in range(3)]
    return [-c[0] / K, c[2] / K, -c[1] / K]   # back to (r, u, f) metres


# ---------------------------------------------------------------- bodies
def make_rig(pre, H, female=False, w=1.0, arm=1.0, leg=1.0, head=1.0, outfit=None,
             face=None, skirt=False, dx=0.0, thin=1.0):
    s = H / 1.78 * w
    hs = H / 1.78
    t = thin
    ankle, knee, hip = .045 * H, .285 * H * leg / leg, .52 * H
    knee = ankle + (.285 - .045) * H * leg / (1 + (leg - 1) * .5)
    hip = knee + (.52 - .285) * H * leg / (1 + (leg - 1) * .5)
    waist = hip + .07 * H
    shoulder = .80 * H
    neck = .82 * H
    top = H
    sx = (.18 if female else .205) * s
    hipx = (.095 if female else .09) * s
    A = (1, 0, 0)
    B = BODY_REG
    atlas = (128, 128)
    parts, joints = {}, []

    def P(name, rs, n, reg, atl=atlas, axis='u', c0=True, c1=True):
        ob = loft(pre + name, [((r[0][0] + dx, r[0][1], r[0][2]),) + tuple(r[1:]) for r in rs], n, reg, atl, axis, c0, c1)
        parts[name] = ob
        return ob

    bust = 1.18 if female else 1.0
    hipw = 1.12 if female else 1.0
    # torso
    P('LowerTorso', [((0, hip - .06 * hs, 0), .10 * s * hipw * t, .09 * s * t),
                     ((0, hip + .02 * hs, 0), .17 * s * hipw * t, .11 * s * t),
                     ((0, waist, 0), (.13 if female else .145) * s * t, .10 * s * t)], 8, B['LT'])
    P('UpperTorso', [((0, waist, 0), (.13 if female else .145) * s * t, .10 * s * t),
                     ((0, shoulder - .12 * hs, .005), (.15 if female else .165) * s * t, .115 * s * bust * t),
                     ((0, shoulder + .03 * hs, -.01), (.17 if female else .2) * s * t, .085 * s * t),
                     ((0, neck + .01 * hs, -.005), .06 * s, .055 * s)], 8, B['UT'])
    # head (own 64x64 face texture)
    hh = (top - neck) * head
    hw = s * (.93 if female else 1.0) * (1 / max(.8, thin) if thin < 1 else 1)
    hw = s * (.93 if female else 1.0)
    hb = neck - .015 * hs
    hz = lambda f_: hb + f_ * hh
    back = 1.15 if female else 1.0   # hair volume at the back
    P('Head', [((0, hb, -.005), .05 * hw, .052 * hw),
               ((0, hz(.25), .012), .068 * hw, .085 * hw),
               ((0, hz(.42), .012), .082 * hw, .098 * hw),
               ((0, hz(.6), .008), .088 * hw, .104 * hw * back, .018 * hw),
               ((0, hz(.75), .004), .09 * hw, .104 * hw * back),
               ((0, hz(.9), .0), .078 * hw, .09 * hw * back),
               ((0, hz(1.0), -.004), .045 * hw, .05 * hw)], 8, FACE_REG['HD'], (64, 64))
    joints.append(('Neck', 'UpperTorso', 'Head', (dx, neck, 0)))
    joints.append(('Waist', 'LowerTorso', 'UpperTorso', (dx, waist, 0)))
    # arms
    ua, la, hd = .175 * H * arm, .145 * H * arm, .105 * H * (1 + (arm - 1) * 1.2)
    for side, sg in (('Left', -1), ('Right', 1)):
        x = sg * sx
        sj = shoulder - .02 * hs
        el, wr = sj - ua, sj - ua - la
        P(side + 'UpperArm', [((x, sj + .03 * hs, 0), .042 * s * t, .045 * s * t),
                              ((x, sj - .03 * hs, 0), .05 * s * t, .052 * s * t),
                              ((x, el, 0), .038 * s * t, .04 * s * t)], 6, B['UA'])
        P(side + 'LowerArm', [((x, el, 0), .038 * s * t, .04 * s * t),
                              ((x, el - .4 * la, .005), .037 * s * t, .039 * s * t),
                              ((x, wr, 0), .028 * s * t, .03 * s * t)], 6, B['LA'])
        P(side + 'Hand', [((x, wr, 0), .03 * s, .02 * s),
                          ((x, wr - .35 * hd, .005), .042 * s, .02 * s),
                          ((x, wr - .8 * hd, .01), .036 * s, .016 * s),
                          ((x, wr - hd, .012), .02 * s, .01 * s)], 6, FACE_REG['HN'], (64, 64))
        joints += [(side + 'Shoulder', 'UpperTorso', side + 'UpperArm', (x + dx, sj, 0)),
                   (side + 'Elbow', side + 'UpperArm', side + 'LowerArm', (x + dx, el, 0)),
                   (side + 'Wrist', side + 'LowerArm', side + 'Hand', (x + dx, wr, 0))]
        lx = sg * hipx
        P(side + 'UpperLeg', [((lx, hip + .04 * hs, 0), .08 * s * t, .085 * s * t),
                              ((lx, hip - .06 * hs, .005), .078 * s * t, .08 * s * t),
                              ((lx, knee, 0), .05 * s * t, .052 * s * t)], 6, B['UL'])
        P(side + 'LowerLeg', [((lx, knee, 0), .05 * s * t, .052 * s * t),
                              ((lx, knee - .3 * (knee - ankle), -.01), .055 * s * t, .058 * s * t),
                              ((lx, ankle, 0), .036 * s * t, .038 * s * t)], 6, B['LL'])
        fl = .26 * hs * (1.0 if not female else .92)
        P(side + 'Foot', [((lx, .04 * hs, -.05 * hs), .038 * s, .04 * hs),
                          ((lx, .036 * hs, .05 * hs), .046 * s, .036 * hs),
                          ((lx, .022 * hs, fl - .07 * hs), .042 * s, .022 * hs, .015 * hs)], 6, B['FT'], axis='f')
        joints += [(side + 'Hip', 'LowerTorso', side + 'UpperLeg', (lx + dx, hip, 0)),
                   (side + 'Knee', side + 'UpperLeg', side + 'LowerLeg', (lx + dx, knee, 0)),
                   (side + 'Ankle', side + 'LowerLeg', side + 'Foot', (lx + dx, ankle, 0))]
    if skirt:
        P('CoatSkirt', [((0, waist - .01 * hs, 0), .16 * s * hipw * t, .12 * s * t),
                        ((0, hip, 0), .185 * s * hipw * t, .13 * s * t),
                        ((0, hip - .2 * hs, -.01), .2 * s * hipw * t, .145 * s * t)], 8, B['SK'], c0=False, c1=False)
    for nm, ob in parts.items():
        if nm in ('Head',) or nm.endswith('Hand'):
            assign(ob, face)
        else:
            assign(ob, outfit)
    data = {
        'height': H,
        'parts': {nm: bbox_center_L(ob) for nm, ob in parts.items()},
        'joints': joints,
        'root': (dx, hip + .04 * hs, 0),
        'eye': (dx, hz(.6), .104 * hw + .004),
    }
    return parts, data


def make_hats(face_ref_head, outfit, dx):
    """hats sized to the male head; centred over neck at x=dx."""
    hs = 1.0
    nk = .82 * 1.78
    hh = 1.78 - nk
    hz = lambda f_: nk - .015 + f_ * hh
    B = BODY_REG
    hats = {}
    hats['FlatCap'] = loft('Acc_FlatCap', [((dx, hz(.74), -.01), .096, .112),
                                           ((dx, hz(.92), -.005), .094, .11),
                                           ((dx, hz(1.03), .01), .075, .095, .06)], 8, B['HAT'], (128, 128))
    hats['WoolHat'] = loft('Acc_WoolHat', [((dx, hz(.7), -.005), .096, .112),
                                           ((dx, hz(.92), -.005), .092, .106),
                                           ((dx, hz(1.06), -.005), .05, .055)], 8, B['HAT'], (128, 128))
    hats['RainHat'] = loft('Acc_RainHat', [((dx, hz(.72), 0), .15, .16),
                                           ((dx, hz(.78), 0), .095, .11),
                                           ((dx, hz(1.04), 0), .08, .09)], 8, B['HAT'], (128, 128))
    for ob in hats.values():
        assign(ob, outfit)
    return {nm: bbox_center_L(ob) for nm, ob in hats.items()}


def make_cast(outfit, x, wr_y):
    ob = loft('Acc_WristCast', [((x, wr_y + .09, 0), .044, .046), ((x, wr_y + .005, 0), .038, .04)],
              6, BODY_REG['CAST'], (128, 128))
    assign(ob, outfit)
    return bbox_center_L(ob)


def make_eyes(name, center, spread, size, mat):
    bm = bmesh.new()
    uv = bm.loops.layers.uv.new('UVMap')
    for sx in (-1, 1):
        c = (center[0] + sx * spread, center[1], center[2])
        pts = [(c[0] + size, c[1], c[2]), (c[0] - size, c[1], c[2]), (c[0], c[1] + size * .6, c[2]),
               (c[0], c[1] - size * .6, c[2]), (c[0], c[1], c[2] + size * .5)]
        v = [bm.verts.new(to_blender(p)) for p in pts]
        for a, b in ((0, 2), (2, 1), (1, 3), (3, 0)):
            fc = bm.faces.new((v[a], v[b], v[4]))
            for loop in fc.loops:
                loop[uv].uv = (.2, .4)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    ob = bpy.data.objects.new(name, me)
    bpy.context.collection.objects.link(ob)
    assign(ob, mat)
    return bbox_center_L(ob)


# ---------------------------------------------------------------- palettes
SKIN = [(196, 160, 132), (172, 128, 98), (120, 86, 62), (214, 182, 156), (150, 108, 80)]
CHANGED = (150, 164, 172)
OUTFITS = {
    # name: (base, spec)
    'Out_M_Casual':   dict(top=(78, 84, 70), under=(150, 140, 120), zip=(40, 40, 40), bottom=(52, 64, 88), belt=(40, 30, 22), shoes=(70, 50, 34)),
    'Out_M_Suit':     dict(top=(56, 58, 66), under=(205, 205, 196), tie=(110, 30, 34), bottom=(52, 54, 62), shoes=(22, 20, 20), skirt=(56, 58, 66)),
    'Out_M_Donkey':   dict(top=(34, 36, 40), collar=(60, 60, 58), buttons=(10, 10, 10), bottom=(70, 62, 48), shoes=(40, 32, 26), hat=(70, 34, 30)),
    'Out_M_Baker':    dict(top=(212, 208, 196), buttons=(170, 168, 160), bottom=(198, 194, 182), apron=(225, 222, 212), shoes=(40, 36, 32), hat=(96, 90, 80)),
    'Out_M_Hoodie':   dict(top=(110, 40, 40), zip=(70, 26, 26), bottom=(60, 60, 64), shoes=(190, 188, 180)),
    'Out_M_Overalls': dict(top=(52, 66, 96), under=(150, 120, 90), bottom=(52, 66, 96), stripe=(200, 190, 60), shoes=(50, 40, 30)),
    'Out_M_Raincoat': dict(top=(150, 130, 90), buttons=(60, 50, 30), belt=(120, 100, 70), bottom=(60, 58, 52), skirt=(150, 130, 90), hat=(120, 104, 74), wet=True),
    'Out_F_RedCoat':  dict(top=(140, 34, 36), buttons=(30, 20, 20), collar=(110, 26, 28), bottom=(50, 44, 48), shin=(70, 60, 58), skirt=(140, 34, 36), shoes=(26, 22, 22)),
    'Out_F_GreyCoat': dict(top=(108, 108, 112), buttons=(40, 40, 40), collar=(90, 90, 94), bottom=(50, 44, 48), shin=(70, 60, 58), skirt=(108, 108, 112), shoes=(26, 22, 22)),
    'Out_F_Nurse':    dict(top=(92, 70, 96), sleeve=(92, 70, 96), under=(120, 150, 160), buttons=(200, 200, 200), bottom=(120, 150, 160), shoes=(220, 220, 214), skirt=(92, 70, 96)),
    'Out_F_Denim':    dict(top=(70, 92, 130), buttons=(170, 150, 90), under=(200, 190, 170), lanyard=(170, 30, 30), bottom=(36, 36, 44), shoes=(30, 30, 30)),
    'Out_F_Cardigan': dict(top=(124, 110, 82), buttons=(70, 60, 40), under=(190, 180, 160), bottom=(70, 62, 80), shin=(180, 150, 130), shoes=(60, 44, 34), skirt=(70, 62, 80)),
    'Out_F_Parka':    dict(top=(68, 80, 56), zip=(30, 30, 30), collar=(140, 120, 90), bottom=(40, 40, 50), shoes=(60, 44, 34), skirt=(68, 80, 56)),
    'Out_F_Raincoat': dict(top=(120, 112, 80), buttons=(50, 40, 30), belt=(100, 90, 60), bottom=(60, 58, 52), shin=(90, 80, 70), skirt=(120, 112, 80), hat=(150, 60, 50), wet=True),
    'Out_RF_Rags':    dict(top=(30, 30, 32), bottom=(28, 28, 30), skirt=(30, 30, 32), tatters=(14, 14, 16), shoes=(130, 136, 140), sleeve=(30, 30, 32), wet=True),
    'Out_RN_Skin':    dict(top=(118, 128, 132), ribs=True, bottom=(40, 40, 42), shin=(118, 128, 132), tatters=(20, 20, 22), shoes=(110, 120, 124), wet=True),
}
FACES = {
    'Face_M1': dict(skin=SKIN[0], hair=(60, 44, 30)),
    'Face_M2': dict(skin=SKIN[2], hair=(20, 18, 16), beard=True),
    'Face_M3': dict(skin=SKIN[3], hair=(150, 146, 140), undereye=.8),      # older
    'Face_Doyle': dict(skin=SKIN[1], hair=(110, 100, 90), beard=True, undereye=.78),
    'Face_Tom': dict(skin=SKIN[0], hair=(150, 110, 60)),
    'Face_F1': dict(skin=SKIN[3], hair=(90, 60, 34), long=True, lipstick=(150, 60, 64)),
    'Face_F2': dict(skin=SKIN[4], hair=(26, 20, 18), long=True),
    'Face_F3': dict(skin=SKIN[0], hair=(170, 170, 166), undereye=.8),        # older (Helen)
    'Face_Mae': dict(skin=SKIN[1], hair=(60, 36, 24), fringe=True),
    'Face_Priya': dict(skin=SKIN[2], hair=(16, 14, 14), long=True),
    'Face_Linda': dict(skin=SKIN[3], hair=(120, 70, 40), long=True, lipstick=(140, 40, 46)),
    # anomaly variants
    'Face_M_Changed': dict(skin=CHANGED, hair=(28, 30, 32), lips=(54, 64, 96), undereye=.7, wet=True),
    'Face_F_Changed': dict(skin=CHANGED, hair=(28, 30, 32), long=True, lips=(54, 64, 96), undereye=.7, wet=True),
    'Face_F_BlackEyes': dict(skin=SKIN[1], hair=(60, 36, 24), fringe=True, blackeyes=True),   # Mae N6
    'Face_F_Smile': dict(skin=SKIN[3], hair=(120, 70, 40), long=True, mouth='smile'),          # the Double
    'Face_M_Smile': dict(skin=SKIN[0], hair=(60, 44, 30), mouth='smile'),
    'Face_M_NoPupils': dict(skin=SKIN[3], hair=(70, 60, 50), nopupils=True),                   # the Still
    'Face_M_Mutant': dict(skin=SKIN[1], hair=(40, 34, 28), mouth='gape', undereye=.7),
    'Face_Faceless': dict(skin=CHANGED, hair=(30, 32, 34), faceless=True, wet=True),           # Walkers
    'Face_RF': dict(skin=(70, 74, 78), hair=(10, 10, 12), long=True, noeyes=True, mouth='line', lips=(20, 10, 10)),
    'Face_RN': dict(skin=(118, 128, 132), bald=True, hair=(90, 98, 102), noeyes=True, mouth='maw'),
}


def clear():
    bpy.ops.object.select_all(action='SELECT')
    bpy.ops.object.delete()


def export(name):
    bpy.ops.object.select_all(action='SELECT')
    bpy.ops.export_scene.fbx(filepath=os.path.join(OUT, name), use_selection=True,
                             path_mode='COPY', embed_textures=True, mesh_smooth_type='FACE',
                             apply_unit_scale=True, bake_space_transform=False, add_leaf_bones=False,
                             object_types={'MESH'})


def tris():
    return sum(len(o.data.polygons) for o in bpy.data.objects if o.type == 'MESH')


def main():
    for f in list(bpy.data.objects):
        bpy.data.objects.remove(f)
    tex = {n: paint_outfit(n, o) for n, o in OUTFITS.items()}
    tex.update({n: paint_face(n, f) for n, f in FACES.items()})
    kit = {'rigs': {}, 'acc': {}}

    # People
    _, kit['rigs']['M'] = make_rig('M_', 1.78, outfit=tex['Out_M_Casual'], face=tex['Face_M1'], skirt=True, dx=0)
    _, kit['rigs']['F'] = make_rig('F_', 1.65, female=True, outfit=tex['Out_F_RedCoat'], face=tex['Face_Linda'], skirt=True, dx=1.2)
    kit['acc']['hat_from_M_head'] = {nm: c for nm, c in make_hats(None, tex['Out_M_Donkey'], -1.2).items()}
    kit['acc']['hat_head_ref'] = (-1.2, .82 * 1.78, 0)
    fdat = kit['rigs']['F']
    wr = [j for j in fdat['joints'] if j[0] == 'RightWrist'][0][3]
    kit['acc']['WristCast'] = make_cast(tex['Out_F_Denim'], wr[0], wr[1])
    kit['acc']['WristCast_ref'] = wr
    print('People tris', tris())
    export('People.fbx')
    clear()
    for o in list(bpy.data.objects):
        bpy.data.objects.remove(o)

    # Monsters
    _, kit['rigs']['RF'] = make_rig('RF_', 2.05, w=.85, arm=1.3, leg=1.1, thin=.7, outfit=tex['Out_RF_Rags'], face=tex['Face_RF'], skirt=True, dx=0)
    kit['rigs']['RF']['eyes'] = make_eyes('RF_Eyes', kit['rigs']['RF']['eye'], .028, .012, tex['Face_RF'])
    _, kit['rigs']['RN'] = make_rig('RN_', 2.18, w=.8, arm=1.55, leg=1.15, thin=.6, head=1.15, outfit=tex['Out_RN_Skin'], face=tex['Face_RN'], dx=1.3)
    _, kit['rigs']['MU'] = make_rig('MU_', 1.78, arm=1.6, outfit=tex['Out_M_Overalls'], face=tex['Face_M_Mutant'], dx=2.6)
    print('Monsters tris', tris())
    export('Monsters.fbx')
    for o in list(bpy.data.objects):
        bpy.data.objects.remove(o)

    # Texture swatches: one quad per texture, laid out in a grid
    for i, (nm, path) in enumerate(sorted(tex.items())):
        bm = bmesh.new()
        uv = bm.loops.layers.uv.new('UVMap')
        x, z = (i % 8) * .5, (i // 8) * .5
        v = [bm.verts.new((x, 0, z)), bm.verts.new((x + .4, 0, z)), bm.verts.new((x + .4, 0, z + .4)), bm.verts.new((x, 0, z + .4))]
        f = bm.faces.new(v)
        for loop, c in zip(f.loops, ((0, 0), (1, 0), (1, 1), (0, 1))):
            loop[uv].uv = c
        me = bpy.data.meshes.new('Tex_' + nm)
        bm.to_mesh(me)
        ob = bpy.data.objects.new('Tex_' + nm, me)
        bpy.context.collection.objects.link(ob)
        assign(ob, path)
    export('Textures.fbx')

    write_lua(kit, sorted(tex))


def lua(v):
    if isinstance(v, dict):
        return '{' + ', '.join(f'{k}={lua(x)}' if k.isidentifier() else f'["{k}"]={lua(x)}' for k, x in v.items()) + '}'
    if isinstance(v, (list, tuple)):
        if v and all(isinstance(x, (int, float)) for x in v):
            return 'Vector3.new(' + ', '.join(f'{x:.4f}' for x in v) + ')'
        return '{' + ', '.join(lua(x) for x in v) + '}'
    if isinstance(v, str):
        return f'"{v}"'
    if isinstance(v, float):
        return f'{v:.4f}'
    return str(v)


def write_lua(kit, texnames):
    with open(os.path.join(OUT, 'CharacterKitData.lua'), 'w') as fh:
        fh.write('-- Generated by tools/characters/build_characters.py. Positions are in the\n'
                 '-- build frame (X = character right, Y = up, Z = front), metres.\n')
        fh.write('return ' + lua({'rigs': kit['rigs'], 'acc': kit['acc'], 'textures': list(texnames)}) + '\n')


main()
