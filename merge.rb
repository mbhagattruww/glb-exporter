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

def self.export(gltf_path, bin_path, ents)
  begin
    # Use only the filename (with extension) for buffers[0].uri (glTF needs relative URI)
    bin_filename = File.basename(bin_path)

    # ---------- helpers ----------
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

    # ---------- collect faces by top-level object ----------
    TopObject = Struct.new(:name, :faces) # faces: [[face, tr_accum]]
    objects = {}                         # key: carrier entity or :__ROOT__ => TopObject
    material_map = {}

    tr_world = self.world_to_gltf

    # Faces directly under root selection/model
    ents.each do |e|
      next if e.hidden?
      if e.respond_to?(:layer) && e.layer && !e.layer.visible?
        next
      end

      case e
      when Sketchup::Face
        key = :__ROOT__
        objects[key] ||= TopObject.new("UntaggedGeometry", [])
        objects[key].faces << [e, Geom::Transformation.new]
      when Sketchup::Group, Sketchup::ComponentInstance
        key = e
        objects[key] ||= TopObject.new(self.entity_label(e), [])
        # collect faces beneath this carrier with accumulated transform
        self.each_visible_face_with_tr(
          e.respond_to?(:entities) ? e.entities : e.definition.entities,
          e.transformation
        ) { |f, tr_accum| objects[key].faces << [f, tr_accum] }
      else
        # descend if it has entities (rare at top level)
        if e.respond_to?(:entities)
          self.each_visible_face_with_tr(e.entities) { |f, tr_accum|
            key = :__ROOT__
            objects[key] ||= TopObject.new("UntaggedGeometry", [])
            objects[key].faces << [f, tr_accum]
          }
        end
      end
    end

    # ---------- init glTF containers ----------
    bin = StringIO.new("".b)
    align4 = ->(io) { pad = (4 - (io.string.bytesize % 4)) % 4; io.write("\x00" * pad) if pad > 0 }

    gltf = {
      asset: { version: "2.0", generator: "Truww Minimal SU→glTF (Named)" },
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

    # ---------- build per-object geometry and write to BIN ----------
    objects.each_value do |obj|
      positions = []
      normals   = []
      uvs       = []
      # mat_idx => { indices: [] }
      prims_by_mat = Hash.new { |h, k| h[k] = { indices: [] } }

      obj.faces.each do |face, tr_inst|
        mesh = face.mesh 7 # include UVs
        next unless mesh

        # choose face material (front/back)
        su_mat = face.material || face.back_material
        mat_key = su_mat ? su_mat.display_name : "_DEFAULT_"
        # ensure material index exists
        material_map[mat_key] ||= material_map.length
        mat_idx = material_map[mat_key]

        pts = mesh.points
        tri_count = mesh.count_polygons

        (1..tri_count).each do |t|
          idxs = mesh.polygon_at(t)
          next unless idxs && idxs.length >= 3

          p3 = []
          v3 = []
          3.times do |k|
            i = idxs[k].abs
            p = pts[i - 1]
            next unless p

            p_model = p.transform(tr_inst)
            p_gl    = p_model.transform(tr_world)

            p3 << p_gl
            v3 << p_gl.x.to_f << p_gl.y.to_f << p_gl.z.to_f

            # UVs
            uvq  = mesh.uv_at(i, true) # front side
            u    = uvq.x / uvq.z
            vtex = uvq.y / uvq.z
            uvs << u.to_f << vtex.to_f
          end
          next unless p3.length == 3

          # flat normal for the triangle
          a = p3[1] - p3[0]
          b = p3[2] - p3[0]
          n = a.cross(b)
          n = (n.length == 0.0) ? Geom::Vector3d.new(0, 0, 1) : n.normalize

          base = positions.length / 3
          positions.concat(v3)
          3.times { normals << n.x.to_f << n.y.to_f << n.z.to_f }

          prims_by_mat[mat_idx][:indices].concat([base, base + 1, base + 2])
        end
      end

      # Skip empty objects
      next if positions.empty?

      # min/max
      xs, ys, zs = [], [], []
      positions.each_slice(3) { |x, y, z| xs << x; ys << y; zs << z }
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
      gltf[:accessors] << { bufferView: bv_pos, componentType: 5126, count: positions.length / 3, type: "VEC3", min: pos_min, max: pos_max }

      # Normals
      align4.call(bin)
      nrm_off = bin.string.bytesize
      bin.write(self.pack_f32(normals))
      nrm_len = bin.string.bytesize - nrm_off
      bv_nrm  = gltf[:bufferViews].length
      gltf[:bufferViews] << { buffer: 0, byteOffset: nrm_off, byteLength: nrm_len, target: 34962 }
      acc_nrm = gltf[:accessors].length
      gltf[:accessors] << { bufferView: bv_nrm, componentType: 5126, count: normals.length / 3, type: "VEC3" }

      # UVs
      align4.call(bin)
      uv_off = bin.string.bytesize
      bin.write(self.pack_f32(uvs))
      uv_len = bin.string.bytesize - uv_off
      bv_uv  = gltf[:bufferViews].length
      gltf[:bufferViews] << { buffer: 0, byteOffset: uv_off, byteLength: uv_len, target: 34962 }
      acc_uv = gltf[:accessors].length
      gltf[:accessors] << { bufferView: bv_uv, componentType: 5126, count: uvs.length / 2, type: "VEC2" }

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

      # Mesh + Node per object (this keeps names!)
      mesh_index = gltf[:meshes].length
      gltf[:meshes] << { name: obj.name, primitives: primitives }
      node_index = gltf[:nodes].length
      gltf[:nodes]  << { name: obj.name, mesh: mesh_index }
      gltf[:scenes][0][:nodes] << node_index
    end

    # ---------- Materials (shared; textures embedded in BIN) ----------
    mat_keys_sorted = material_map.keys.sort_by { |k| material_map[k] }
    mat_keys_sorted.each do |key|
      su_mat = key == "_DEFAULT_" ? nil : Sketchup.active_model.materials[key]
      if su_mat && su_mat.texture
        tex = su_mat.texture
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

        gltf[:materials] << {
          name: su_mat.display_name,
          pbrMetallicRoughness: {
            baseColorTexture: { index: textures.length - 1 },
            metallicFactor: 0.0, roughnessFactor: 0.5
          }
        }
      else
        gltf[:materials] << {
          name: (su_mat ? su_mat.display_name : "Default"),
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

    # sanity: bufferViews must reference buffer 0 and fit
    max_used = 0
    gltf[:bufferViews].each_with_index do |bv, i|
      raise "bufferView[#{i}] must reference buffer 0" unless bv[:buffer] == 0
      end_off = (bv[:byteOffset] || 0) + (bv[:byteLength] || 0)
      max_used = [max_used, end_off].max
    end
    raise "BIN smaller than used bufferViews" if bin_data.bytesize < max_used

    # ---------- write files ----------
    File.binwrite(bin_path, bin_data)
    File.write(gltf_path, JSON.pretty_generate(gltf))
  rescue => e
    UI.messagebox("Export failed: #{e.class}: #{e.message}\n#{e.backtrace&.first}")
  end
end
