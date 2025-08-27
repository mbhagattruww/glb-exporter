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
def self.each_visible_face_with_tr(entities, tr_accum = Geom::Transformation.new, mat_override = nil, &block)
  entities.each do |e|
    next if e.hidden?
    if e.respond_to?(:layer) && e.layer && !e.layer.visible?
      next
    end

    case e
    when Sketchup::Face
      yield e, tr_accum, mat_override
    when Sketchup::Group
      child_override = e.material || mat_override
      each_visible_face_with_tr(e.entities, tr_accum * e.transformation, child_override, &block)
    when Sketchup::ComponentInstance
      child_override = e.material || mat_override
      each_visible_face_with_tr(e.definition.entities, tr_accum * e.transformation, child_override, &block)
    end
  end
end

def self.export(gltf_path, bin_path, ents)
  begin
    bin_filename = File.basename(bin_path) # keep .bin
    tr_world = self.world_to_gltf

    # ---------- small helpers ----------
    def self.entity_label(e)
      case e
      when Sketchup::Group
        e.name.to_s.strip.empty? ? "Group_#{e.entityID}" : e.name
      when Sketchup::ComponentInstance
        nm = e.name.to_s.strip
        nm = e.definition&.name.to_s if nm.empty?
        nm = "Component_#{e.entityID}" if nm.nil? || nm.strip.empty?
        nm
      else
        "UntaggedGeometry"
      end
    end

    def self.visible?(e)
      return false if e.hidden?
      return false if e.respond_to?(:layer) && e.layer && !e.layer.visible?
      true
    end

    # Global accumulators
    bin = StringIO.new("".b)
    align4 = ->(io) { pad = (4 - (io.string.bytesize % 4)) % 4; io.write("\x00" * pad) if pad > 0 }

    gltf = {
      asset: { version: "2.0", generator: "Truww Minimal SU→glTF (Hierarchy)" },
      scenes: [ { nodes: [] } ],
      scene: 0,
      nodes: [],
      buffers: [],
      bufferViews: [],
      accessors: [],
      materials: [],
      meshes: []
    }
    images   = []
    textures = []

    # ✅ Key materials by the Material object (or :__DEFAULT__), not by display name
    material_map = {} # { (Sketchup::Material or :__DEFAULT__) => material_index }

    # One TextureWriter for all UV helpers (OPTIONAL; safe to keep)
    tw = Sketchup::TextureWriter.new

    # Build (or fetch) material index
    get_mat_idx = lambda do |su_mat|
      key = su_mat || :__DEFAULT__
      material_map[key] = material_map.length unless material_map.key?(key)
      material_map[key]
    end

    # Emit a mesh for faces (no recursion here): faces is [[face, tr_accum, inst_mat], ...]
    emit_mesh_for = lambda do |node_name, faces|
      positions = []
      normals   = []
      uvs       = []
      prims_by_mat = Hash.new { |h, k| h[k] = { indices: [] } }

      faces.each do |face, tr_accum, inst_mat|
        next unless face && self.visible?(face)
        mesh = face.mesh 7
        next unless mesh

        # Effective material (respect parent override + back side)
        front_mat   = face.material || inst_mat
        back_mat    = face.back_material || inst_mat
        using_front = !!front_mat
        eff_mat     = front_mat || back_mat # may be nil => :__DEFAULT__

        mat_idx = get_mat_idx.call(eff_mat)

        pts = mesh.points
        tri_count = mesh.count_polygons

        # UV helper – use TextureWriter version (or omit 3rd arg if you prefer)
        uvh = face.get_UVHelper(true, true, tw)

        (1..tri_count).each do |t|
          idxs = mesh.polygon_at(t)
          next unless idxs && idxs.length >= 3

          p3 = []
          v3 = []
          3.times do |k|
            i = idxs[k].abs
            p = pts[i - 1]
            next unless p

            p_model = p.transform(tr_accum)
            p_gl    = p_model.transform(tr_world)

            p3 << p_gl
            v3 << p_gl.x.to_f << p_gl.y.to_f << p_gl.z.to_f

            # Correct UVs for the side in use
            uvq = using_front ? uvh.get_front_UVQ(p) : uvh.get_back_UVQ(p)
            u   = uvq.x / uvq.z
            vv  = uvq.y / uvq.z
            uvs << u.to_f << vv.to_f
          end
          next unless p3.length == 3

          a = p3[1] - p3[0]; b = p3[2] - p3[0]
          n = a.cross(b); n = (n.length == 0.0) ? Geom::Vector3d.new(0,0,1) : n.normalize

          base = positions.length / 3
          positions.concat(v3)
          3.times { normals << n.x.to_f << n.y.to_f << n.z.to_f }

          prims_by_mat[mat_idx][:indices].concat([base, base + 1, base + 2])
        end
      end

      return nil if positions.empty?

      # min/max
      xs, ys, zs = [], [], []
      positions.each_slice(3) { |x,y,z| xs<<x; ys<<y; zs<<z }
      pos_min = [xs.min || 0, ys.min || 0, zs.min || 0]
      pos_max = [xs.max || 0, ys.max || 0, zs.max || 0]

      # Positions
      align4.call(bin)
      pos_off = bin.string.bytesize
      bin.write(self.pack_f32(positions))
      pos_len = bin.string.bytesize - pos_off
      bv_pos  = gltf[:bufferViews].length
      gltf[:bufferViews] << { buffer: 0, byteOffset: pos_off, byteLength: pos_len, target: 34962 }
      acc_pos = gltf[:accessors].length
      gltf[:accessors] << { bufferView: bv_pos, componentType: 5126, count: positions.length/3, type: "VEC3", min: pos_min, max: pos_max }

      # Normals
      align4.call(bin)
      nrm_off = bin.string.bytesize
      bin.write(self.pack_f32(normals))
      nrm_len = bin.string.bytesize - nrm_off
      bv_nrm  = gltf[:bufferViews].length
      gltf[:bufferViews] << { buffer: 0, byteOffset: nrm_off, byteLength: nrm_len, target: 34962 }
      acc_nrm = gltf[:accessors].length
      gltf[:accessors] << { bufferView: bv_nrm, componentType: 5126, count: normals.length/3, type: "VEC3" }

      # UVs
      align4.call(bin)
      uv_off = bin.string.bytesize
      bin.write(self.pack_f32(uvs))
      uv_len = bin.string.bytesize - uv_off
      bv_uv  = gltf[:bufferViews].length
      gltf[:bufferViews] << { buffer: 0, byteOffset: uv_off, byteLength: uv_len, target: 34962 }
      acc_uv = gltf[:accessors].length
      gltf[:accessors] << { bufferView: bv_uv, componentType: 5126, count: uvs.length/2, type: "VEC2" }

      # Indices per material => primitives
      primitives = []
      prims_by_mat.each do |mat_idx, prim|
        next if prim[:indices].empty?

        align4.call(bin)
        idx_off = bin.string.bytesize
        bin.write(self.pack_u32(prim[:indices]))
        idx_len = bin.string.bytesize - idx_off

        bv_idx  = gltf[:bufferViews].length
        gltf[:bufferViews] << { buffer: 0, byteOffset: idx_off, byteLength: idx_len, target: 34963 }
        acc_idx = gltf[:accessors].length
        gltf[:accessors] << { bufferView: bv_idx, componentType: 5125, count: prim[:indices].length, type: "SCALAR" }

        primitives << {
          attributes: { "POSITION" => acc_pos, "NORMAL" => acc_nrm, "TEXCOORD_0" => acc_uv },
          indices: acc_idx,
          material: mat_idx,
          mode: 4
        }
      end

      mesh_index = gltf[:meshes].length
      gltf[:meshes] << { name: node_name, primitives: primitives }
      mesh_index
    end

    # Faces directly contained in an entity (NO recursion), but pass the parent override
    faces_immediate = lambda do |entities, tr_accum, inst_mat|
      list = []
      entities.each do |e|
        next unless self.visible?(e)
        list << [e, tr_accum, inst_mat] if e.is_a?(Sketchup::Face)
      end
      list
    end

    # Recursive walk → create node, attach mesh (from its own faces), then children
    walk_entity = lambda do |carrier, tr_parent|
      name = self.entity_label(carrier)
      node = { name: name }
      node_index = gltf[:nodes].length
      gltf[:nodes] << node

      child_ents = carrier.is_a?(Sketchup::ComponentInstance) ? carrier.definition.entities : carrier.entities
      faces = faces_immediate.call(child_ents, tr_parent * carrier.transformation, carrier.material)
      if !faces.empty?
        mesh_index = emit_mesh_for.call(name, faces)
        node[:mesh] = mesh_index if mesh_index
      end

      # Recurse into groups/instances
      children = []
      child_ents.each do |e|
        next unless self.visible?(e)
        if e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
          ci = walk_entity.call(e, tr_parent * carrier.transformation)
          children << ci
        end
      end
      node[:children] = children unless children.empty?
      node_index
    end

    # Root scene: faces + top-level children
    root_faces = []
    root_children = []

    ents.each do |e|
      next unless self.visible?(e)
      case e
      when Sketchup::Face
        root_faces << [e, Geom::Transformation.new, nil]
      when Sketchup::Group, Sketchup::ComponentInstance
        root_children << walk_entity.call(e, Geom::Transformation.new)
      else
        if e.respond_to?(:entities)
          root_faces.concat(faces_immediate.call(e.entities, Geom::Transformation.new, nil))
          e.entities.each do |c|
            if (c.is_a?(Sketchup::Group) || c.is_a?(Sketchup::ComponentInstance)) && self.visible?(c)
              root_children << walk_entity.call(c, Geom::Transformation.new)
            end
          end
        end
      end
    end

    if !root_faces.empty?
      name = "UntaggedGeometry"
      mesh_index = emit_mesh_for.call(name, root_faces)
      root_node = { name: name, mesh: mesh_index }
      gltf[:nodes] << root_node
      gltf[:scenes][0][:nodes] << (gltf[:nodes].length - 1)
    end

    gltf[:scenes][0][:nodes].concat(root_children) unless root_children.empty?

    # ---------- materials (shared; embed textures in BIN) ----------
    # Build materials array in *exact* indices as in material_map
    gltf[:materials] = Array.new(material_map.length)

    material_map.each do |key, idx|
      su_mat = (key == :__DEFAULT__) ? nil : key # key is Material or :__DEFAULT__

      if su_mat && su_mat.texture
        tex = su_mat.texture

        # Write the image bytes into BIN (PNG/JPG) – TextureWriter baking optional
        tmp_path = File.join(Dir.tmpdir, "tex.png")
        tex.write(tmp_path)
        img_data = File.binread(tmp_path)

        align4.call(bin)
        img_off = bin.string.bytesize
        bin.write(img_data)
        img_len = bin.string.bytesize - img_off

        bv_tex = gltf[:bufferViews].length
        gltf[:bufferViews] << { buffer: 0, byteOffset: img_off, byteLength: img_len }

        img_index = images.length
        images   << { bufferView: bv_tex, mimeType: "image/png" }
        textures << { source: img_index }

        gltf[:materials][idx] = {
          name: (su_mat.display_name rescue su_mat.name),
          pbrMetallicRoughness: {
            baseColorTexture: { index: textures.length - 1 },
            metallicFactor: 0.0, roughnessFactor: 0.5
          }
        }
      else
        gltf[:materials][idx] = {
          name: su_mat ? ((su_mat.display_name rescue su_mat.name) || "Material") : "Default",
          pbrMetallicRoughness: {
            baseColorFactor: self.color_to_basecolorfactor(su_mat),
            metallicFactor: 0.0, roughnessFactor: 0.5
          }
        }
      end
    end

    gltf[:images]   = images unless images.empty?
    gltf[:textures] = textures unless textures.empty?

    # ---------- finalize buffers ----------
    bin_data = bin.string
    pad = (4 - (bin_data.bytesize % 4)) % 4
    bin_data += "\x00" * pad if pad > 0

    gltf[:buffers] = [{ byteLength: bin_data.bytesize, uri: bin_filename }]

    # sanity
    max_used = 0
    gltf[:bufferViews].each_with_index do |bv, i|
      raise "bufferView[#{i}] must reference buffer 0" unless bv[:buffer] == 0
      end_off = (bv[:byteOffset] || 0) + (bv[:byteLength] || 0)
      max_used = [max_used, end_off].max
    end
    raise "BIN smaller than used bufferViews" if bin_data.bytesize < max_used

    File.binwrite(bin_path, bin_data)
    File.write(gltf_path, JSON.pretty_generate(gltf))
  rescue => e
    UI.messagebox("Export failed: #{e.class}: #{e.message}\n#{e.backtrace&.first}")
  end
end
