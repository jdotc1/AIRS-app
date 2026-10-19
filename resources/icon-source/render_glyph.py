"""AIRS app-icon glyph: photoreal inertial reference sphere rendered in Blender Cycles.

Run: /Applications/Blender.app/Contents/MacOS/Blender -b -P resources/icon-source/render_glyph.py -- out.png [steel|champagne] [pixels] [samples] [base|large|xl]
Orthographic camera at 32 deg elevation; copper seams cross as an X; ports sit front-left and on the right limb.
The seam/port geometry is defined in a y-up frame (x right, y up, z toward camera) and mapped to Blender as (x, -z, y).
The transparent PNG output becomes resources/AIRS.icon/Assets/glyph.png (see docs/ICON.md).
"""
import bpy, bmesh, glob, math, os, sys
from mathutils import Vector, Matrix

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
OUT = argv[0] if argv else "/tmp/airs8.png"
VARIANT = argv[1] if len(argv) > 1 else "steel"
RES = int(argv[2]) if len(argv) > 2 else 1024
SAMPLES = int(argv[3]) if len(argv) > 3 else 256
# Glyph size: "base" = original framing; "large"/"xl" slim the flange and zoom in so the sphere reads in the Dock.
SIZE = argv[4] if len(argv) > 4 else "xl"
FRAME = {"base": (1.24, 1.42, 3.40, -0.035), "large": (1.20, 1.34, 2.90, -0.045),
         "xl": (1.18, 1.30, 2.66, -0.05)}[SIZE]

ELEV = math.radians(32)
H0 = -0.16                      # flange top plane (sphere radius = 1)
RI = 1.07
RM, RO = FRAME[0], FRAME[1]


def b(v):                       # y-up design vector -> Blender vector
    return Vector((v[0], -v[2], v[1]))


def nrm(v):
    v = Vector(v); return v.normalized()


# ---------- sphere orientation (seams N1, N2; ports) ----------
def basis7(d):
    d = Vector(d)
    u = (d.cross(Vector((0, 1, 0))) if abs(d.y) < 0.95 else d.cross(Vector((1, 0, 0)))).normalized()
    return u, d.cross(u)


A7 = nrm((0.30, 0.62, 0.72))
_u, _v = basis7(A7)
PHI = math.radians(38)
N1_7 = (_u * math.cos(PHI) + _v * math.sin(PHI)).normalized()
N2_7 = A7.cross(N1_7)


def quadrant7(s1, s2, th):
    q = (N1_7 * s1 + N2_7 * s2).normalized()
    return (A7 * math.cos(th) + q * math.sin(th)).normalized()


N1, N2 = b(N1_7), b(N2_7)
PORT1, PORT2 = b(quadrant7(1, -1, math.radians(52))), b(quadrant7(-1, 1, math.radians(52)))

# ---------- scene ----------
bpy.ops.wm.read_factory_settings(use_empty=True)
sc = bpy.context.scene
sc.render.engine = "CYCLES"
prefs = bpy.context.preferences.addons["cycles"].preferences
prefs.compute_device_type = "METAL"
prefs.get_devices()
for d in prefs.devices:
    d.use = True
sc.cycles.device = "GPU"
sc.cycles.samples = SAMPLES
sc.cycles.use_denoising = True
sc.cycles.max_bounces = 8
sc.cycles.glossy_bounces = 6
sc.render.film_transparent = True
sc.render.resolution_x = sc.render.resolution_y = RES
sc.render.image_settings.file_format = "PNG"
sc.render.image_settings.color_mode = "RGBA"
sc.render.image_settings.color_depth = "8"
sc.view_settings.view_transform = "AgX"
sc.view_settings.look = "AgX - Medium High Contrast"
sc.view_settings.exposure = -0.30


# ---------- materials ----------
def principled(name, color, metal, rough, aniso=0.0, aniso_rot=0.0, coat=0.0):
    m = bpy.data.materials.new(name); m.use_nodes = True
    p = m.node_tree.nodes["Principled BSDF"]
    p.inputs["Base Color"].default_value = (*color, 1)
    p.inputs["Metallic"].default_value = metal
    p.inputs["Roughness"].default_value = rough
    p.inputs["Anisotropic"].default_value = aniso
    p.inputs["Anisotropic Rotation"].default_value = aniso_rot
    p.inputs["Coat Weight"].default_value = coat
    return m


FLANGE = {"steel": (0.78, 0.79, 0.81), "champagne": (0.86, 0.80, 0.66)}[VARIANT]
M = dict(
    alu=principled("alu", FLANGE, 1.0, 0.36, aniso=0.8),
    gun=principled("gun", (0.035, 0.037, 0.042), 0.0, 0.32, coat=0.3),
    alu_dark=principled("alu_dark", tuple(c * 0.55 for c in FLANGE), 1.0, 0.35, aniso=0.6),
    bezel=principled("bezel", (0.86, 0.87, 0.88), 1.0, 0.16, aniso=0.6),
    gold=principled("gold", (0.95, 0.58, 0.12), 1.0, 0.26),
    vespel=principled("vespel", (0.90, 0.20, 0.02), 0.0, 0.42, coat=0.2),
    cream=principled("cream", (0.84, 0.79, 0.66), 0.0, 0.45),
    black=principled("black", (0.02, 0.02, 0.022), 0.0, 0.6),
    screw=principled("screw", (0.55, 0.56, 0.58), 1.0, 0.30),
)


def sphere_material():
    m = bpy.data.materials.new("sphere"); m.use_nodes = True
    nt = m.node_tree; N = nt.nodes; L = nt.links
    N.clear()
    out = N.new("ShaderNodeOutputMaterial")
    tc = N.new("ShaderNodeTexCoord")
    nv = N.new("ShaderNodeVectorMath"); nv.operation = "NORMALIZE"
    L.new(tc.outputs["Object"], nv.inputs[0])

    def seam_dist(n):
        d = N.new("ShaderNodeVectorMath"); d.operation = "DOT_PRODUCT"
        d.inputs[1].default_value = n
        L.new(nv.outputs[0], d.inputs[0])
        a = N.new("ShaderNodeMath"); a.operation = "ABSOLUTE"
        L.new(d.outputs["Value"], a.inputs[0])
        return a.outputs[0]

    mn = N.new("ShaderNodeMath"); mn.operation = "MINIMUM"
    L.new(seam_dist(N1), mn.inputs[0]); L.new(seam_dist(N2), mn.inputs[1])
    dist = mn.outputs[0]

    def step(edge):            # 1 inside |dot| < edge, antialiased
        s = N.new("ShaderNodeMapRange"); s.interpolation_type = "SMOOTHSTEP"
        s.inputs["From Min"].default_value = edge + 0.0015
        s.inputs["From Max"].default_value = edge - 0.0015
        L.new(dist, s.inputs["Value"])
        return s.outputs["Result"]

    copper_in, cream_in, groove_in = step(0.040), step(0.048), step(0.052)

    steel = N.new("ShaderNodeBsdfPrincipled")
    steel.inputs["Base Color"].default_value = (0.62, 0.63, 0.65, 1)
    steel.inputs["Metallic"].default_value = 1.0
    steel.inputs["Anisotropic"].default_value = 0.35
    # faint polishing marks
    noise = N.new("ShaderNodeTexNoise"); noise.inputs["Scale"].default_value = 90
    noise.inputs["Detail"].default_value = 8
    L.new(tc.outputs["Object"], noise.inputs["Vector"])
    rr = N.new("ShaderNodeMapRange")
    rr.inputs["To Min"].default_value = 0.26; rr.inputs["To Max"].default_value = 0.36
    L.new(noise.outputs["Fac"], rr.inputs["Value"])
    L.new(rr.outputs["Result"], steel.inputs["Roughness"])

    copper = N.new("ShaderNodeBsdfPrincipled")
    copper.inputs["Base Color"].default_value = (0.80, 0.24, 0.07, 1)
    copper.inputs["Metallic"].default_value = 1.0
    copper.inputs["Roughness"].default_value = 0.45
    cream = N.new("ShaderNodeBsdfPrincipled")
    cream.inputs["Base Color"].default_value = (0.86, 0.81, 0.67, 1)
    cream.inputs["Roughness"].default_value = 0.45

    mix1 = N.new("ShaderNodeMixShader")      # steel / cream
    L.new(cream_in, mix1.inputs[0]); L.new(steel.outputs[0], mix1.inputs[1]); L.new(cream.outputs[0], mix1.inputs[2])
    mix2 = N.new("ShaderNodeMixShader")      # .. / copper
    L.new(copper_in, mix2.inputs[0]); L.new(mix1.outputs[0], mix2.inputs[1]); L.new(copper.outputs[0], mix2.inputs[2])
    L.new(mix2.outputs[0], out.inputs["Surface"])

    # strap sits in a shallow groove: height drops at the groove, copper slightly proud of the cream
    h = N.new("ShaderNodeMath"); h.operation = "SUBTRACT"
    h.inputs[0].default_value = 1.0
    L.new(groove_in, h.inputs[1])
    h2 = N.new("ShaderNodeMath"); h2.operation = "MULTIPLY_ADD"
    h2.inputs[2].default_value = 0.0
    L.new(copper_in, h2.inputs[0]); h2.inputs[1].default_value = 0.6
    hs = N.new("ShaderNodeMath"); hs.operation = "ADD"
    L.new(h.outputs[0], hs.inputs[0]); L.new(h2.outputs[0], hs.inputs[1])
    bump = N.new("ShaderNodeBump"); bump.inputs["Strength"].default_value = 0.6
    bump.inputs["Distance"].default_value = 0.004
    L.new(hs.outputs[0], bump.inputs["Height"])
    for s in (steel, copper, cream):
        L.new(bump.outputs["Normal"], s.inputs["Normal"])
    return m


# ---------- geometry helpers ----------
def smooth(o):
    for p in o.data.polygons:
        p.use_smooth = True


def bevel(o, w=0.004, seg=3):
    m = o.modifiers.new("bev", "BEVEL"); m.width = w; m.segments = seg
    m.limit_method = "ANGLE"; m.harden_normals = False


def lathe(name, prof, mats, seg_mat, steps=384):
    """Revolve a closed (r, z) profile around Blender Z."""
    me = bpy.data.meshes.new(name); bm = bmesh.new()
    rings = []
    for i in range(steps):
        a = 2 * math.pi * i / steps
        rings.append([bm.verts.new((r * math.cos(a), r * math.sin(a), z)) for r, z in prof])
    n = len(prof)
    for i in range(steps):
        r0, r1 = rings[i], rings[(i + 1) % steps]
        for j in range(n):
            k = (j + 1) % n
            f = bm.faces.new((r0[k], r1[k], r1[j], r0[j])); f.material_index = seg_mat[j]
    bm.to_mesh(me); bm.free()
    o = bpy.data.objects.new(name, me); sc.collection.objects.link(o)
    for mt in mats:
        o.data.materials.append(mt)
    for p in o.data.polygons:
        p.use_smooth = True
    m = o.modifiers.new("ws", "WEIGHTED_NORMAL"); m.keep_sharp = True
    o.data.set_sharp_from_angle(angle=math.radians(35)) if hasattr(o.data, "set_sharp_from_angle") else None
    return o


def cyl(name, r, depth, mat, verts=96, at=Vector(), rot=Matrix(), bev=0.003):
    bpy.ops.mesh.primitive_cylinder_add(vertices=verts, radius=r, depth=depth)
    o = bpy.context.active_object; o.name = name
    o.matrix_world = Matrix.Translation(at) @ rot.to_4x4()
    o.data.materials.append(mat)
    if bev:
        bevel(o, bev)
    smooth(o)
    o.data.set_sharp_from_angle(angle=math.radians(40)) if hasattr(o.data, "set_sharp_from_angle") else None
    return o


# ---------- sphere ----------
bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=7, radius=1.0)
sph = bpy.context.active_object; sph.name = "sphere"; smooth(sph)
sph.data.materials.append(sphere_material())

# ---------- flange (one lathe: bore floor, bore wall, lip, step, outer ring, skirt) ----------
z0 = H0
prof = [
    (0.0, -0.75), (1.10, -0.75),                 # dark bore floor
    (1.10, z0 - 0.06), (RI, z0 - 0.04),          # bore wall up to the lip chamfer
    (RI, z0 + 0.012), (RI + 0.012, z0 + 0.024),  # inner lip
    (1.15, z0 + 0.024), (1.162, z0 + 0.012),
    (1.162, z0), (RM - 0.01, z0),                # main face
    (RM, z0 - 0.01), (RM, z0 - 0.045),           # step down
    (RO - 0.012, z0 - 0.045), (RO, z0 - 0.057),  # outer ring
    (RO, z0 - 0.16), (0.0, -0.16 + z0),          # skirt
]
# drop the duplicate centre closure: profile is closed by lathe faces
# 0 black, 1 machined bright, 2 gunmetal face, 3 satin outer ring
fl = lathe("flange", prof, [M["black"], M["alu"], M["gun"], M["alu_dark"]],
           [0, 0, 2, 1, 1, 1, 1, 1, 3, 1, 1, 2, 1, 2, 0, 0])
# darker bore so the sphere seats in shadow
bore = cyl("bore", 1.095, 0.12, M["black"], verts=192, at=Vector((0, 0, z0 - 0.10)), bev=0)

# cap screws on the outer ring
NB = 20
for i in range(NB):
    a = 2 * math.pi * (i + 0.5) / NB
    p = Vector(((RM + RO) / 2 * math.cos(a), (RM + RO) / 2 * math.sin(a), z0 - 0.045))
    cyl(f"bolt{i}", 0.026, 0.024, M["screw"], verts=32, at=p + Vector((0, 0, 0.010)), bev=0.004)
    cyl(f"sock{i}", 0.011, 0.01, M["black"], verts=6, at=p + Vector((0, 0, 0.0225)), bev=0)


# ---------- ports ----------
def port(d, s, ring_mat):
    d = d.normalized()
    rot = d.to_track_quat("Z", "Y").to_matrix()

    def at(h):
        return d * h
    cyl("bezel", 0.20 * s, 0.07 * s, M["bezel"], at=at(1.0 + 0.0 * s), rot=rot, bev=0.006 * s)
    cyl("ring", 0.145 * s, 0.05 * s, ring_mat, at=at(1.035 * 1 + 0.004 * s), rot=rot, bev=0.006 * s)
    cyl("seat", 0.118 * s, 0.05 * s, M["alu_dark"], at=at(1.045 + 0.004 * s), rot=rot, bev=0.004 * s)
    # square sensor mount, rotated 45 deg, with a gold hex in it
    r45 = rot @ Matrix.Rotation(math.radians(45), 3, "Z")
    cyl("mount", 0.112 * s, 0.05 * s, M["gold"], verts=4, at=at(1.055 + 0.004 * s), rot=r45, bev=0.004 * s)
    cyl("hex", 0.060 * s, 0.05 * s, M["gold"], verts=6, at=at(1.07 + 0.004 * s), rot=rot, bev=0.003 * s)
    cyl("hexsock", 0.022 * s, 0.02 * s, M["black"], verts=6, at=at(1.09 + 0.006 * s), rot=rot, bev=0)
    u = rot.col[0]; v = rot.col[1]
    for k in range(6):
        a = 2 * math.pi * k / 6 + math.radians(30)
        p = d * 1.036 + (u * math.cos(a) + v * math.sin(a)) * 0.172 * s
        cyl("pscrew", 0.012 * s, 0.012 * s, M["black"], verts=16, at=p, rot=rot, bev=0)


port(PORT1, 1.25, M["vespel"] if VARIANT == "champagne" else M["cream"])
port(PORT2, 1.0, M["vespel"] if VARIANT == "champagne" else M["cream"])

# tapped holes scattered on the shell, as in the photographs
import random
random.seed(7)
holes = 0
while holes < 14:
    d = Vector((random.uniform(-1, 1), random.uniform(-1, 1), random.uniform(-0.1, 1))).normalized()
    if d.dot(Vector((0, -math.cos(ELEV), math.sin(ELEV)))) < 0.25 or d.z < H0 + 0.12:
        continue
    if min(abs(d.dot(N1)), abs(d.dot(N2))) < 0.09 or d.dot(PORT1) > 0.93 or d.dot(PORT2) > 0.95:
        continue
    cyl("tap", 0.014, 0.02, M["black"], verts=20, at=d * 0.995, rot=d.to_track_quat("Z", "Y").to_matrix(), bev=0)
    holes += 1

# ---------- lights + world ----------
w = bpy.data.worlds.new("w"); sc.world = w; w.use_nodes = True
wn = w.node_tree.nodes; wl = w.node_tree.links
env = wn.new("ShaderNodeTexEnvironment")
env.image = bpy.data.images.load(sorted(glob.glob(os.path.join(os.path.dirname(bpy.app.binary_path), "..", "Resources", "*", "datafiles", "studiolights", "world", "studio.exr")))[-1])
mp = wn.new("ShaderNodeMapping"); mp.inputs["Rotation"].default_value = (0, 0, math.radians(200))
tc = wn.new("ShaderNodeTexCoord")
wl.new(tc.outputs["Generated"], mp.inputs["Vector"]); wl.new(mp.outputs[0], env.inputs["Vector"])
# studio sweep: dark floor, grey horizon, bright ceiling, HDRI adds structure to the reflections
sep = wn.new("ShaderNodeSeparateXYZ"); wl.new(tc.outputs["Generated"], sep.inputs[0])
ramp = wn.new("ShaderNodeValToRGB"); cr = ramp.color_ramp
cr.elements[0].position = 0.40; cr.elements[0].color = (0.015, 0.015, 0.017, 1)
cr.elements[1].position = 1.00; cr.elements[1].color = (0.75, 0.76, 0.78, 1)
e = cr.elements.new(0.50); e.color = (0.10, 0.10, 0.11, 1)
e = cr.elements.new(0.62); e.color = (0.42, 0.43, 0.45, 1)
mz = wn.new("ShaderNodeMapRange"); mz.inputs["From Min"].default_value = -1; mz.inputs["From Max"].default_value = 1
wl.new(sep.outputs["Z"], mz.inputs["Value"]); wl.new(mz.outputs["Result"], ramp.inputs["Fac"])
mix = wn.new("ShaderNodeMix"); mix.data_type = "RGBA"; mix.blend_type = "MULTIPLY"
mix.inputs["Factor"].default_value = 0.55
wl.new(ramp.outputs["Color"], mix.inputs["A"]); wl.new(env.outputs["Color"], mix.inputs["B"])
wl.new(mix.outputs["Result"], wn["Background"].inputs["Color"])
wn["Background"].inputs["Strength"].default_value = 0.4


def area(name, loc, size, energy, color=(1, 1, 1), sy=None):
    l = bpy.data.lights.new(name, "AREA"); l.energy = energy; l.color = color
    if sy:
        l.shape = "RECTANGLE"; l.size = size; l.size_y = sy
    else:
        l.size = size
    o = bpy.data.objects.new(name, l); sc.collection.objects.link(o)
    o.location = loc
    o.rotation_euler = (Vector((0, 0, 0)) - Vector(loc)).to_track_quat("-Z", "Y").to_euler()
    return o


area("key", (-3.0, -2.5, 4.5), 1.6, 750, sy=5.0)     # strip softbox, upper left: long highlight on the sphere
area("fill", (4.0, -3.5, 2.0), 3.0, 260, (0.92, 0.95, 1.0))
area("rim", (2.0, 2.5, 7.0), 2.5, 500)
area("top", (0.0, 0.0, 6.0), 5.0, 120)


# ---------- camera ----------
cam = bpy.data.cameras.new("cam"); cam.type = "ORTHO"; cam.ortho_scale = FRAME[2]
co = bpy.data.objects.new("cam", cam); sc.collection.objects.link(co); sc.camera = co
D = 20
co.location = (0, -D * math.cos(ELEV), D * math.sin(ELEV))
co.rotation_euler = (Vector((0, 0, 0)) - co.location).to_track_quat("-Z", "Y").to_euler()
cam.shift_y = FRAME[3]

sc.render.filepath = OUT
bpy.ops.render.render(write_still=True)
print("WROTE", OUT)
