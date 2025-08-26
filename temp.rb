# Plugins/truww_gltf_exporter.rb
# Minimal glTF 2.0 exporter for SketchUp geometry (positions + indices).
# (c) You. MIT-style; use at your own risk.

require 'json'
require 'fileutils'
require 'stringio'

module Truww
  module GLTF
PLUGIN_NAME = "Export glTF (.gltf + .bin Minimal)".freeze

# ...

    # ---- Helpers -------------------------------------------------------------
    def self.pack_f32(arr); arr.pack('e*'); end
    def self.pack_u32(arr); arr.pack('L<*'); end

    def self.rotation_minus_90deg_x
      Geom::Transformation.new([
        1,0,0,0,
        0,0,-1,0,
        0,1,0,0,
        0,0,0,1
      ])
    end

# Replace the whole method with a fixed inches→meters scale
def self.model_units_to_meters
  Geom::Transformation.scaling(0.0254)  # inches → meters
end

    def self.world_to_gltf
      self.model_units_to_meters * self.rotation_minus_90deg_x
    end

    def self.color_to_basecolorfactor(su_material)
      if su_material && su_material.color
        c = su_material.color
        a = (su_material.alpha || 1.0).to_f
        [c.red/255.0, c.green/255.0, c.blue/255.0, a]
      else
        [0.8,0.8,0.8,1.0]
      end
    end

# Walk visible faces and carry the accumulated transform (groups/components)
def self.each_visible_face_with_tr(entities, tr_accum = Geom::Transformation.new, &block)
  entities.each do |e|
    # Skip hidden or tag/layer turned off
    next if e.hidden?
    if e.respond_to?(:layer) && e.layer && !e.layer.visible?
      next
    end

    case e
    when Sketchup::Face
      yield e, tr_accum
    when Sketchup::Group
      each_visible_face_with_tr(e.entities, tr_accum * e.transformation, &block)
    when Sketchup::ComponentInstance
      each_visible_face_with_tr(e.definition.entities, tr_accum * e.transformation, &block)
    end
  end
end
    
    # ---- Core Export ---------------------------------------------------------
    def self.export
      path = UI.savepanel("Export glTF (Minimal .gltf + .bin)", Dir.pwd, "model.gltf")
      return unless path
      gltf_path = path
      base = File.basename(gltf_path, ".*")
      dir  = File.dirname(gltf_path)
      bin_filename = "#{base}.bin"
      bin_path     = File.join(dir, bin_filename)
      model = Sketchup.active_model
      sel   = model.selection
      ents  = sel.empty? ? model.entities : sel

      triangles = []
      positions = []
      normals   = []     # NEW
      material_map = {}
      prims = []

      def self.primitive_for_material(material_map, prims, su_material)
        key = su_material ? su_material.display_name : "_DEFAULT_"
        unless material_map.key?(key)
          mat_index = material_map.length
          material_map[key] = mat_index
          prims << { mat_idx: mat_index, indices: [] }
        end
        idx = material_map[key]
        prims.find { |p| p[:mat_idx] == idx }
      end

tr_world = self.world_to_gltf
model.start_operation("Export glTF (Minimal .gltf + .bin)", true)

uvs = []

each_visible_face_with_tr(ents) do |face, tr_inst|
  mesh = face.mesh 7  # include UVs
  next unless mesh

  su_mat = face.material || face.back_material
  prim = primitive_for_material(material_map, prims, su_mat)
  pts = mesh.points
  tri_count = mesh.count_polygons

  (1..tri_count).each do |t|
    idxs = mesh.polygon_at(t)
    next unless idxs && idxs.length >= 3

    v  = []
    p3 = []
    uvtri = []
    3.times do |k|
      i = idxs[k].abs
      p = pts[i - 1]
      next unless p

      p_model = p.transform(tr_inst)
      p_gl    = p_model.transform(tr_world)
    
      p3 << p_gl
      v  << p_gl.x.to_f << p_gl.y.to_f << p_gl.z.to_f
    
      # UV from mesh
      uvq = mesh.uv_at(i, true)   # front side
      u = uvq.x / uvq.z
      vtex = uvq.y / uvq.z
      uvs << u.to_f << vtex.to_f

    end
    next unless p3.length == 3

    # Normal
    a = p3[1] - p3[0]
    b = p3[2] - p3[0]
    n = a.cross(b)
    n = (n.length == 0.0) ? Geom::Vector3d.new(0,0,1) : n.normalize

    base = positions.length / 3
    positions.concat(v)
    3.times { normals << n.x.to_f << n.y.to_f << n.z.to_f }
    uvtri.each { |u,vv| uvs << u << vv }  # push 2D UVs
    prim[:indices].concat([base, base+1, base+2])
  end
end
      bin = StringIO.new("".b)
      align4 = ->(io){ pad = (4 - (io.string.bytesize % 4)) % 4; io.write("\x00"*pad) if pad > 0 }

      minmax = ->(arr){
        xs,ys,zs = [],[],[]
        arr.each_slice(3){|x,y,z| xs<<x; ys<<y; zs<<z}
        [[xs.min||0,ys.min||0,zs.min||0],[xs.max||0,ys.max||0,zs.max||0]]
      }
      pos_min,pos_max = minmax.call(positions)


# ---- Build bufferViews / accessors in correct order -------------------
# Create the root glTF object (must exist before you set bufferViews/accessors)
gltf = {
  asset: { version: "2.0", generator: "Truww Minimal SU→glTF" },
  scenes: [{ nodes: [0] }],
  scene: 0,
  nodes: [{ mesh: 0, name: "Root" }],
  buffers: [],        # will set after writing BIN
  bufferViews: [],    # we will fill now
  accessors: [],      # we will fill now
  materials: [],
  meshes: []
}
      
gltf[:bufferViews] = []
gltf[:accessors]   = []
gltf[:meshes]      = []

# Positions
align4.call(bin)
pos_offset = bin.string.bytesize
bin.write(pack_f32(positions))
pos_length = bin.string.bytesize - pos_offset

gltf[:bufferViews] << {
  buffer: 0,
  byteOffset: pos_offset,
  byteLength: pos_length,
  target: 34962 # ARRAY_BUFFER
}
gltf[:accessors] << {
  bufferView: gltf[:bufferViews].length - 1,
  componentType: 5126, # FLOAT
  count: positions.length / 3,
  type: "VEC3",
  min: pos_min,
  max: pos_max
}
acc_pos = gltf[:accessors].length - 1

# Normals (flat per-triangle; already built to match positions count)
align4.call(bin)
nrm_offset = bin.string.bytesize
bin.write(pack_f32(normals))
nrm_length = bin.string.bytesize - nrm_offset

# TEXCOORD_0
align4.call(bin)
uv_off = bin.string.bytesize
bin.write(pack_f32(uvs))
uv_len = bin.string.bytesize - uv_off

gltf[:bufferViews] << {
  buffer: 0,
  byteOffset: uv_off,
  byteLength: uv_len,
  target: 34962
}
gltf[:accessors] << {
  bufferView: gltf[:bufferViews].length - 1,
  componentType: 5126, # FLOAT
  count: uvs.length / 2,
  type: "VEC2"
}
acc_uv = gltf[:accessors].length - 1



gltf[:bufferViews] << {
  buffer: 0,
  byteOffset: nrm_offset,
  byteLength: nrm_length,
  target: 34962 # ARRAY_BUFFER
}
gltf[:accessors] << {
  bufferView: gltf[:bufferViews].length - 1,
  componentType: 5126, # FLOAT
  count: normals.length / 3,
  type: "VEC3"
}
acc_nrm = gltf[:accessors].length - 1

images   = []
textures = []

mat_keys_sorted = material_map.keys.sort_by { |k| material_map[k] }
mat_keys_sorted.each do |key|
  su_mat = key == "_DEFAULT_" ? nil : Sketchup.active_model.materials[key]

  if su_mat && su_mat.texture
    tex = su_mat.texture
    tmp_path = File.join(Dir.tmpdir, "tex.png")
    tex.write(tmp_path)
    img_data = File.binread(tmp_path)

    # Align to 4 bytes
    align4.call(bin)
    img_off = bin.string.bytesize
    bin.write(img_data)
    img_len = bin.string.bytesize - img_off

    bv_idx = gltf[:bufferViews].length
    gltf[:bufferViews] << {
      buffer: 0,
      byteOffset: img_off,
      byteLength: img_len
    }

    img_index = images.length
    images << {
      bufferView: bv_idx,
      mimeType: "image/png"
    }
    textures << { source: img_index }

    pbr = {
      pbrMetallicRoughness: {
        baseColorTexture: { index: textures.length - 1 },
        metallicFactor: 0.0, roughnessFactor: 0.5
      },
      name: su_mat.display_name
    }
    gltf[:materials] << pbr

  else
    # Fallback flat color
    pbr = {
      pbrMetallicRoughness: {
        baseColorFactor: self.color_to_basecolorfactor(su_mat),
        metallicFactor: 0.0, roughnessFactor: 0.5
      },
      name: (su_mat ? su_mat.display_name : "Default")
    }
    gltf[:materials] << pbr
  end
end

gltf[:images]   = images   unless images.empty?
gltf[:textures] = textures unless textures.empty?

# Indices per primitive — write and wire
prim_entries = []
prims.each do |p|
  align4.call(bin)
  idx_off = bin.string.bytesize
  bin.write(pack_u32(p[:indices]))
  idx_len = bin.string.bytesize - idx_off

  gltf[:bufferViews] << {
    buffer: 0,
    byteOffset: idx_off,
    byteLength: idx_len,
    target: 34963 # ELEMENT_ARRAY_BUFFER
  }
  gltf[:accessors] << {
    bufferView: gltf[:bufferViews].length - 1,
    componentType: 5125, # UNSIGNED_INT
    count: p[:indices].length,
    type: "SCALAR"
  }
  acc_idx = gltf[:accessors].length - 1

  prim_entries << {
    attributes: { "POSITION" => acc_pos, "NORMAL" => acc_nrm, "TEXCOORD_0" => acc_uv },
    indices: acc_idx,
    material: p[:mat_idx],
    mode: 4 # TRIANGLES
  }
end

gltf[:meshes] << { primitives: prim_entries, name: "Mesh" }

# ---- AFTER writing everything, set the final buffer length -------------
gltf[:buffers] = [{ byteLength: bin.string.bytesize }]


  
# ---- Finalize external BIN + write .bin/.gltf -------------------------

# 4-byte align the BIN so all bufferView byteOffsets remain valid
bin_data = bin.string
bin_pad  = (4 - (bin_data.bytesize % 4)) % 4
bin_data += "\x00" * bin_pad if bin_pad > 0

# Point buffers[0] to external .bin (must be an array with 1 entry)
gltf[:buffers] = [{
  byteLength: bin_data.bytesize,
  uri: bin_filename
}]

# Optional quick sanity check: ensure no bufferView exceeds BIN size
max_used = 0
gltf[:bufferViews].each_with_index do |bv, i|
  raise "bufferView[#{i}] must reference buffer 0" unless bv[:buffer] == 0
  end_off = (bv[:byteOffset] || 0) + (bv[:byteLength] || 0)
  max_used = [max_used, end_off].max
end
raise "BIN smaller than used bufferViews" if bin_data.bytesize < max_used

# Write the .bin
File.binwrite(bin_path, bin_data)

# Write the .gltf (pretty or compact; pretty helps debugging)
json_str = JSON.pretty_generate(gltf)
File.write(gltf_path, json_str)

model.commit_operation
UI.messagebox("Exported:\n#{gltf_path}\n#{bin_path}")
    rescue => e
      model.abort_operation
      UI.messagebox("Export failed: #{e.class}: #{e.message}\n#{e.backtrace&.first}")
    end

    # ---- UI -----------------------------------------------------------------
    UI.add_context_menu_handler { |menu| menu.add_item(PLUGIN_NAME){ self.export } }
    UI.menu("File").add_item(PLUGIN_NAME){ self.export }
    @menu_installed = true
  end
end
