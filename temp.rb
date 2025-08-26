# Plugins/truww_gltf_exporter.rb
# Minimal glTF 2.0 exporter for SketchUp geometry (positions + indices).
# (c) You. MIT-style; use at your own risk.

require 'json'
require 'fileutils'
require 'stringio'

module Truww
  module GLTF
    PLUGIN_NAME = "Export glTF (.glb Minimal)".freeze

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

    # Fixed: Use model.options to scale according to SketchUp units
    def self.model_units_to_meters
      model = Sketchup.active_model
      unit_code = model.options["UnitsOptions"]["LengthUnit"]

      scale = case unit_code
        when 0 # Inches
          0.0254
        when 1 # Feet
          0.3048
        when 2 # Millimeters
          0.001
        when 3 # Centimeters
          0.01
        when 4 # Meters
          1.0
        else
          0.0254 # default to inches
      end

      Geom::Transformation.scaling(scale)
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

    # ---- Core Export ---------------------------------------------------------
    def self.export
      model = Sketchup.active_model
      sel   = model.selection
      ents  = sel.empty? ? model.entities : sel

      path = UI.savepanel("Export glTF (Minimal .glb)", Dir.pwd, "model.glb")
      return unless path
      glb_path = path

      triangles = []
      positions = []
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
      model.start_operation("Export glTF (Minimal .glb)", true)

      def self.each_face(entities, &block)
        entities.grep(Sketchup::Face).each { |f| yield f }
        entities.grep(Sketchup::Group).each { |g| each_face(g.entities, &block) }
        entities.grep(Sketchup::ComponentInstance).each { |i| each_face(i.definition.entities, &block) }
      end

      each_face(ents) do |face|
        mesh = face.mesh(0)
        next unless mesh
        su_mat = face.material || face.back_material
        prim = primitive_for_material(material_map, prims, su_mat)
        pts = mesh.points
        tri_count = mesh.count_polygons
        (1..tri_count).each do |t|
          idxs = mesh.polygon_at(t)
          next unless idxs && idxs.length >= 3
          v = []
          3.times do |k|
            i = idxs[k].abs
            p = pts[i - 1]   # FIX: 1-based -> 0-based
            next unless p
            p4 = Geom::Point3d.new(p.x, p.y, p.z).transform(tr_world)
            v << p4.x.to_f << p4.y.to_f << p4.z.to_f
          end
          base = positions.length / 3
          positions.concat(v)
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

      align4.call(bin)
      pos_buffer_view_offset = bin.string.bytesize
      bin.write(pack_f32(positions))
      pos_byte_length = bin.string.bytesize - pos_buffer_view_offset

      prim_buffers = prims.map do |p|
        align4.call(bin)
        off = bin.string.bytesize
        bin.write(pack_u32(p[:indices]))
        len = bin.string.bytesize - off
        { byteOffset: off, byteLength: len, count: p[:indices].length }
      end

      gltf = {
        asset: { version: "2.0", generator: "Truww Minimal SU→glTF" },
        scenes: [{ nodes: [0] }],
        scene: 0,
        nodes: [{ mesh: 0, name: "Root" }],
        buffers: [{ byteLength: bin.string.bytesize }],
        bufferViews: [],
        accessors: [],
        materials: [],
        meshes: []
      }

      acc_pos_index = gltf[:accessors].length
      # gltf[:bufferViews] << {
      #   buffer: 0,
      #   byteOffset: 0,
      #   byteLength: bin.string.bytesize,
      #   target: 34962
      # }
      # --- Build bufferViews / accessors correctly ------------------------------
      gltf[:bufferViews] = []
      gltf[:accessors] = []

      # Position bufferView: use the actual offset and length where positions were written
      gltf[:bufferViews] << {
        buffer: 0,
        byteOffset: pos_buffer_view_offset,
        byteLength: pos_byte_length,
        target: 34962
      }
      gltf[:accessors] << {
        bufferView: 0,
        componentType: 5126,
        count: positions.length / 3,
        type: "VEC3",
        min: pos_min,
        max: pos_max
      }
      acc_pos_index = 0

      # Materials (unchanged)
      mat_keys_sorted = material_map.keys.sort_by { |k| material_map[k] }
      mat_keys_sorted.each do |key|
        su_mat = key == "_DEFAULT_" ? nil : Sketchup.active_model.materials[key]
        pbr = {
          pbrMetallicRoughness: {
            baseColorFactor: self.color_to_basecolorfactor(su_mat),
            metallicFactor: 0.0, roughnessFactor: 0.5
          },
          name: (su_mat ? su_mat.display_name : "Default")
        }
        gltf[:materials] << pbr
      end

      # For each primitive: create a bufferView for its indices and an accessor
      prim_entries = []
      prims.each_with_index do |p, i|
        pb = prim_buffers[i]
        bv_idx = gltf[:bufferViews].length
        gltf[:bufferViews] << {
          buffer: 0,
          byteOffset: pb[:byteOffset],
          byteLength: pb[:byteLength],
          target: 34963
        }
        acc_idx = gltf[:accessors].length
        gltf[:accessors] << {
          bufferView: bv_idx,
          componentType: 5125,    # UNSIGNED_INT
          count: pb[:count],
          type: "SCALAR"
        }
        prim_entries << {
          attributes: { "POSITION" => acc_pos_index },
          indices: acc_idx,
          material: p[:mat_idx],
          mode: 4
        }
      end

      gltf[:meshes] << { primitives: prim_entries, name: "Mesh" }

      prim_entries = []
      prims.each_with_index do |p,i|
        bv_idx = gltf[:bufferViews].length
        gltf[:bufferViews] << {
          buffer: 0, byteOffset: prim_buffers[i][:byteOffset],
          byteLength: prim_buffers[i][:byteLength], target: 34963
        }
        acc_idx = gltf[:accessors].length
        gltf[:accessors] << {
          bufferView: bv_idx, componentType: 5125,
          count: prim_buffers[i][:count], type: "SCALAR"
        }
        prim_entries << {
          attributes: { POSITION: acc_pos_index },
          indices: acc_idx, material: p[:mat_idx], mode: 4
        }
      end
      gltf[:meshes] << { primitives: prim_entries, name: "Mesh" }

      # ---- Write GLB ---------------------------------------------------------
      json_str = JSON.generate(gltf)
      json_pad = (4 - (json_str.bytesize % 4)) % 4
      json_str += " " * json_pad

      bin_data = bin.string
      bin_pad = (4 - (bin_data.bytesize % 4)) % 4
      bin_data += "\x00" * bin_pad

      File.open(glb_path, "wb") do |f|
        f.write("glTF".b)                          
        f.write([2].pack("L<"))                    
        total_len = 12 + 8 + json_str.bytesize + 8 + bin_data.bytesize
        f.write([total_len].pack("L<"))            

        f.write([json_str.bytesize].pack("L<"))
        f.write(["JSON".b].pack("A4"))
        f.write(json_str)

        f.write([bin_data.bytesize].pack("L<"))
        f.write(["BIN".b].pack("A4"))
        f.write(bin_data)
      end

      model.commit_operation
      UI.messagebox("Exported:\n#{glb_path}")
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
