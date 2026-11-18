extends RefCounted

static func material(color: String, metallic: float = 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(color)
	m.roughness = 0.78
	m.metallic = metallic
	return m

static func sphere(parent: Node3D, label: String, pos: Vector3, size: Vector3, mat: Material, segments: int = 24) -> MeshInstance3D:
	var mesh := SphereMesh.new()
	mesh.radius = 0.5
	mesh.height = 1.0
	mesh.radial_segments = segments
	mesh.rings = maxi(segments / 2, 4)
	return instance(parent, label, pos, size, mesh, mat)

static func box(parent: Node3D, label: String, pos: Vector3, size: Vector3, mat: Material) -> MeshInstance3D:
	return instance(parent, label, pos, size, BoxMesh.new(), mat)

static func cylinder(parent: Node3D, label: String, pos: Vector3, radius: float, height: float, mat: Material, top: float = -1.0, segments: int = 12) -> MeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius if top < 0 else top
	mesh.bottom_radius = radius
	mesh.height = height
	mesh.radial_segments = segments
	return instance(parent, label, pos, Vector3.ONE, mesh, mat)

static func pivot(parent: Node3D, label: String, pos: Vector3) -> Node3D:
	var n := Node3D.new()
	n.name = label
	n.position = pos
	parent.add_child(n)
	return n

static func instance(parent: Node3D, label: String, pos: Vector3, size: Vector3, mesh: Mesh, mat: Material) -> MeshInstance3D:
	var n := MeshInstance3D.new()
	n.name = label
	n.mesh = mesh
	n.material_override = mat
	n.position = pos
	n.scale = size
	parent.add_child(n)
	return n
