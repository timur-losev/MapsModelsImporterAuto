Google Maps' "draped" shader (2026)
===================================

Google Maps switched to a vertex shader the importer was not written against.
Captures still import, but four things go wrong at once, and they compound
into results that look unrelated to their causes. This note records what the
shader does, so the next change to it is cheaper to chase.

Older captures — Google Earth, and Maps captures predating this shader, such
as the project's `venise` sample — take the same code paths as before and are
unaffected.

What the shader does
--------------------

Positions arrive as four raw bytes and are converted with `utof`, so they are
integers 0–255, not the normalised values the classic shader stored:

```
 1: utof r1.xyzw, v0.xyzw
...
10: mul r2.xyzw, _uuModelviewMatrix[3].yyyy, _uuMeshToWorldMatrix[1].xyzw
11: mad r2.xyzw, _uuModelviewMatrix[3].xxxx, _uuMeshToWorldMatrix[0].xyzw, r2.xyzw
12: mad r2.xyzw, _uuModelviewMatrix[3].zzzz, _uuMeshToWorldMatrix[2].xyzw, r2.xyzw
13: mad r2.xyzw, _uuModelviewMatrix[3].wwww, l(0.0000, 0.0000, 0.0000, 1.0000), r2.xyzw
15: dp4 r2.w, r2.xyzw, r1.xyzw
```

so the placement is `Modelview * MeshToWorld * (x, y, z, 1)` with no scale
factor. Multiplying the positions by 256, as the classic path does, makes
every tile about two orders of magnitude larger than the spacing between
tiles, and they overlap into a heap.

Texture coordinates are a plain affine transform of the second texcoord
attribute:

```
55: mad o3.xy, v2.xyxx, _uuTexCoordScaleBias.xyxx, _uuTexCoordScaleBias.zwzz
```

`_uuTexCoordScaleBias` is `[scale_u, scale_v, bias_u, bias_v]` — the reverse
of the `[offset, offset, scale, scale]` layout `resolveUniformsFromHints`
scores against, so the heuristic can never recognise it and falls through to
whatever vec4 ties first. In one capture that was `_umoonDirAtmoTimesPhase`,
the moon direction, which is `[0, 0, 0, 0]`.

The attribute itself moved. The UV used to sit at a fixed index; this layout
puts 8-bit normals there and the texture coordinates one slot along. Reading
normals as a UV still produces something that looks roughly like a city,
which makes it an unpleasant one to notice.

The mesh-to-world matrix's bottom row is not a transform
--------------------------------------------------------

It looks projective — `(0, 0, 1, 240)`, `(0, 0, 1, 15)`, `(0, 0, 1, 255)` —
and it is a bitmask. The shader replaces that row with `(0, 0, 0, 1)` (line
13 above) and reads only its last element:

```
 1: utof r1.xyzw, v0.xyzw                      // r1.w = float(v0.w)
 2: add  r0.y, r1.w, r1.w                      // 2 * v0.w
 3: div  r0.y, _uuMeshToWorldMatrix[3].w, r0.y
 4: round_ni r0.z, r0.y                        // floor
 5: add  r0.y, -r0.z, r0.y                     // frac
 6: add  r0.y, r0.y, r0.y                      // * 2
 7: round_ni r0.y, r0.y                        // one bit
 8: ne   r0.z, v3.w, _uuNoDraw_NoDrapeLayer.x
 9: and  r0.y, r0.y, r0.z
...
36: mul  r1.xyzw, r0.yyyy, r1.xyzw             // clip position *= that bit
```

`v0.w` is exactly a power of two, 1 to 128: the eight children of an octree
node. The mask says which of them this tile is responsible for, the
neighbouring finer tiles covering the rest. A cleared bit puts the vertex on
the origin so its triangles degenerate away. `vertexLodMask()` implements
this. On every capture tested it culls nothing — Google only uploads the
children the mask keeps — but a capture where it does would otherwise stitch
unrelated parts of a tile together.

The second test on line 8 is a "no-draw layer" check. Measured across 304
tile draws, the constant is always `-1.0` while `v3.w` is only ever 0 or 2, so
it never fires. (`v3.w == 2` gates an optional projective overlay sampled from
the shared 4096x2048 atlas; the tile's own colour comes from `textures2D[1]`.)

V is flipped, and why that was hard to see
------------------------------------------

The fragment shader samples the tile's colour with `v = 0` at the texture's
top row, which is also how RenderDoc writes the png the importer loads.
Blender puts `v = 0` at the bottom, so the importer has to flip.

On a single aerial photo a missing flip would mirror the image and be obvious.
A tile's texture is not a photo: it is a photogrammetry UV atlas, several
charts stacked vertically (256x768, 256x512, 512x512 …). Flipping V there
hands each piece of the mesh a chart from somewhere else, so the tile renders
as a recognisable city shattered into displaced facets — "some of this is
clearly not from here" rather than "this is upside down". It invites you to
look for a geometry bug, and the geometry is fine.

Settling a question like that against the capture
-------------------------------------------------

Guessing at it costs days; the replay answers it in one run. RenderDoc's
Python module gives both the post-vertex-shader output and the framebuffer, so
a tile can be drawn twice and the pixels compared:

1. `GetPostVSData(0, 0, rd.MeshDataStage.VSOut)` returns exact clip-space
   positions and the draw's own index buffer, so the vertex shader does not
   have to be replayed by hand.
2. `SaveTexture` of the render target at the draw and at the draw before it,
   diffed, isolates the pixels *that single draw* wrote.
3. Rasterise the tile into the real viewport from those positions. A depth
   buffer and perspective-correct UVs are not optional: without depth the
   tile's own walls paint over its roofs and the result looks shattered no
   matter what the UVs do, which is a good way to confirm the wrong theory.
4. Score each candidate reading by mean absolute difference over the pixels
   both images cover, blurred 4x so that mip selection and the shader's 4-tap
   supersampling stop dominating.

| reading of the UV pair | mean difference, raw / blurred |
| --- | --- |
| V flipped relative to the png | 8.3 / **1.2** |
| V as the png stores it | 72.4 / 20.6 |
| U and V swapped, V flipped | 71.9 / 21.8 |
| U and V swapped | 73.7 / 21.1 |

1.2 out of 255 is agreement within filtering and the shader's atmospheric
term. The same method answers any "am I reading this field correctly?"
question about a capture, which is worth more than this particular answer.

Things that look like causes and are not
----------------------------------------

Measured and ruled out while chasing the above, recorded so they are not
chased again:

- the index buffer and the draw's offsets (uint16, `min 0`, `max = vertex
  count - 1`, every offset zero);
- tiles sharing a colour texture (298 distinct textures across 300 draws);
- the add-on's "last bound read-only resource" heuristic picking the wrong
  texture (it picks the real `textures2D[1]` on 100% of tile draws — the
  shader declares only two textures);
- more than one render pass or camera (one render target, one viewport, one
  modelview across all 304 tile draws);
- filtering triangles to a single subdivision level — triangles genuinely do
  span several, `position.w` is a child index and not a level tag.

Roughly a quarter of a typical capture's tile imagery is simply never
uploaded: the texture comes back part black. That is a capture-timing
property, not something the importer can fix.
