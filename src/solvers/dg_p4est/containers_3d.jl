# Initialize data structures in element container
function init_elements!(elements, mesh::P4estMesh{3}, basis::LobattoLegendreBasis)
  @unpack node_coordinates, jacobian_matrix,
          contravariant_vectors, inverse_jacobian = elements

  calc_node_coordinates!(node_coordinates, mesh, basis.nodes)

  for element in 1:ncells(mesh)
    calc_jacobian_matrix!(jacobian_matrix, element, node_coordinates, basis)

    calc_contravariant_vectors!(contravariant_vectors, element, jacobian_matrix,
                                node_coordinates, basis)

    calc_inverse_jacobian!(inverse_jacobian, element, jacobian_matrix, basis)
  end

  return nothing
end


# Interpolate tree_node_coordinates to each quadrant
function calc_node_coordinates!(node_coordinates,
                                mesh::P4estMesh{3},
                                nodes)
  # Hanging nodes will cause holes in the mesh if its polydeg is higher
  # than the polydeg of the solver.
  @assert length(nodes) >= length(mesh.nodes) "The solver can't have a lower polydeg than the mesh"

  # Macros from p4est
  p4est_root_len = 1 << P4EST_MAXLEVEL
  p4est_quadrant_len(l) = 1 << (P4EST_MAXLEVEL - l)

  trees = unsafe_wrap_sc(p8est_tree_t, mesh.p4est.trees)

  for tree in eachindex(trees)
    offset = trees[tree].quadrants_offset
    quadrants = unsafe_wrap_sc(p8est_quadrant_t, trees[tree].quadrants)

    for i in eachindex(quadrants)
      element = offset + i
      quad = quadrants[i]

      quad_length = p4est_quadrant_len(quad.level) / p4est_root_len

      nodes_out_x = 2 * (quad_length * 1/2 * (nodes .+ 1) .+ quad.x / p4est_root_len) .- 1
      nodes_out_y = 2 * (quad_length * 1/2 * (nodes .+ 1) .+ quad.y / p4est_root_len) .- 1
      nodes_out_z = 2 * (quad_length * 1/2 * (nodes .+ 1) .+ quad.z / p4est_root_len) .- 1

      matrix1 = polynomial_interpolation_matrix(mesh.nodes, nodes_out_x)
      matrix2 = polynomial_interpolation_matrix(mesh.nodes, nodes_out_y)
      matrix3 = polynomial_interpolation_matrix(mesh.nodes, nodes_out_z)

      multiply_dimensionwise!(
        view(node_coordinates, :, :, :, :, element),
        matrix1, matrix2, matrix3,
        view(mesh.tree_node_coordinates, :, :, :, :, tree)
      )
    end
  end

  return node_coordinates
end


@inline function init_interface_node_indices!(interfaces::InterfaceContainerP4est{3},
                                              faces, orientation, interface_id)
  # TODO P4EST revise and comment
  right_handed1 = faces[1] in (1, 2, 5)
  right_handed2 = faces[2] in (1, 2, 5)

  flipped = right_handed1 == right_handed2

  lower = argmin(faces)

  # Iterate over primary and secondary element
  for side in 1:2
    # Align interface at the primary element (primary element has surface indices (:i, :j)).
    # For orientation != 0, the secondary element needs to be indexed differently.
    #
    # In all the folowing illustrations, p4est's face corner numbering is shown.
    # ξ and η are the local coordinates of the respective face.
    # We're looking at both faces in the same physical direction, so that the primary
    # element (on the left) has right-handed coordinates.
    if side == lower || (!flipped && orientation == 0)
      # Corner 0 of first side matches corner 0 of second side.
      #
      #   2┌──────┐3   2┌──────┐3
      #    │      │     │      │
      #    │      │     │      │
      #   0└──────┘1   0└──────┘1
      #     η            η
      #     ↑            ↑
      #     │            │
      #     └───> ξ      └───> ξ
      surface_index1 = :i
      surface_index2 = :j
      # TODO P4EST Switch if both are in negative directions!!!!!!!!!
    elseif flipped && orientation == 0
      # Corner 0 of first side matches corner 0 of second side.
      #
      #   2┌──────┐3   1┌──────┐3
      #    │      │     │      │
      #    │      │     │      │
      #   0└──────┘1   0└──────┘2
      #     η            ξ
      #     ↑            ↑
      #     │            │
      #     └───> ξ      └───> η
      surface_index1 = :j
      surface_index2 = :i
    elseif !flipped && orientation == 1
      # Corner 0 of first side matches corner 1 of second side.
      # Face corner numbering as in p4est,
      # ξ and η are the local coordinates of the respective face.
      #
      #   2┌──────┐3   0┌──────┐2
      #    │      │     │      │
      #    │      │     │      │
      #   0└──────┘1   1└──────┘3
      #     η            ┌───> η
      #     ↑            │
      #     │            ↓
      #     └───> ξ      ξ
      surface_index1 = :j_backwards
      surface_index2 = :i
    elseif flipped && orientation == 1
      # Corner 0 of first side matches corner 1 of second side.
      # Face corner numbering as in p4est,
      # ξ and η are the local coordinates of the respective face.
      #
      #   2┌──────┐3   3┌──────┐2
      #    │      │     │      │
      #    │      │     │      │
      #   0└──────┘1   1└──────┘0
      #     η                 η
      #     ↑                 ↑
      #     │                 │
      #     └───> ξ     ξ <───┘
      surface_index1 = :i_backwards
      surface_index2 = :j
    elseif !flipped && orientation == 2
      if faces == (4, 2)
        @info "" interface_id
      end
      # Corner 0 of first side matches corner 2 of second side.
      # Face corner numbering as in p4est,
      # ξ and η are the local coordinates of the respective face.
      #
      #   2┌──────┐3   3┌──────┐1
      #    │      │     │      │
      #    │      │     │      │
      #   0└──────┘1   2└──────┘0
      #     η                 ξ
      #     ↑                 ↑
      #     │                 │
      #     └───> ξ     η <───┘
      surface_index1 = :j
      surface_index2 = :i_backwards
    elseif flipped && orientation == 2
      # Corner 0 of first side matches corner 2 of second side.
      # Face corner numbering as in p4est,
      # ξ and η are the local coordinates of the respective face.
      #
      #   2┌──────┐3   0┌──────┐1
      #    │      │     │      │
      #    │      │     │      │
      #   0└──────┘1   2└──────┘3
      #     η            ┌───> ξ
      #     ↑            │
      #     │            ↓
      #     └───> ξ      η
      surface_index1 = :i
      surface_index2 = :j_backwards
    elseif !flipped && orientation == 3
      # Corner 0 of first side matches corner 3 of second side.
      # Face corner numbering as in p4est,
      # ξ and η are the local coordinates of the respective face.
      #
      #   2┌──────┐3   1┌──────┐0
      #    │      │     │      │
      #    │      │     │      │
      #   0└──────┘1   3└──────┘2
      #     η           ξ <───┐
      #     ↑                 │
      #     │                 ↓
      #     └───> ξ           η
      surface_index1 = :i_backwards
      surface_index2 = :j_backwards
    else # flipped && orientation == 3
      # Corner 0 of first side matches corner 3 of second side.
      # Face corner numbering as in p4est,
      # ξ and η are the local coordinates of the respective face.
      #
      #   2┌──────┐3   2┌──────┐0
      #    │      │     │      │
      #    │      │     │      │
      #   0└──────┘1   3└──────┘1
      #     η           η <───┐
      #     ↑                 │
      #     │                 ↓
      #     └───> ξ           ξ
      surface_index1 = :j_backwards
      surface_index2 = :i_backwards
    end

    if faces[side] == 0
      # Index face in negative x-direction
      interfaces.node_indices[side, interface_id] = (:one, surface_index1, surface_index2)
    elseif faces[side] == 1
      # Index face in positive x-direction
      interfaces.node_indices[side, interface_id] = (:end, surface_index1, surface_index2)
    elseif faces[side] == 2
      # Index face in negative y-direction
      interfaces.node_indices[side, interface_id] = (surface_index1, :one, surface_index2)
    elseif faces[side] == 3
      # Index face in positive y-direction
      interfaces.node_indices[side, interface_id] = (surface_index1, :end, surface_index2)
    elseif faces[side] == 4
      # Index face in negative z-direction
      interfaces.node_indices[side, interface_id] = (surface_index1, surface_index2, :one)
    else # faces[side] == 5
      # Index face in positive z-direction
      interfaces.node_indices[side, interface_id] = (surface_index1, surface_index2, :end)
    end
  end

  return interfaces
end

function init_interfaces!(interfaces, mesh::P4estMesh{3})
  # Let p4est iterate over all interfaces and call init_interfaces_iter_face
  iter_face_c = @cfunction(init_interfaces_iter_face, Cvoid, (Ptr{p8est_iter_face_info_t}, Ptr{Cvoid}))
  user_data = [interfaces, 1, mesh]

  iterate_faces(mesh.p4est, iter_face_c, user_data)

  return interfaces
end


@inline function init_boundary_node_indices!(boundaries::BoundaryContainerP4est{3},
                                             face, boundary_id)
  if face == 0
    # Index face in negative x-direction
    boundaries.node_indices[boundary_id] = (:one, :i, :j)
  elseif face == 1
    # Index face in positive x-direction
    boundaries.node_indices[boundary_id] = (:end, :i, :j)
  elseif face == 2
    # Index face in negative y-direction
    boundaries.node_indices[boundary_id] = (:i, :one, :j)
  elseif face == 3
    # Index face in positive y-direction
    boundaries.node_indices[boundary_id] = (:i, :end, :j)
  elseif face == 4
    # Index face in negative z-direction
    boundaries.node_indices[boundary_id] = (:i, :j, :one)
  else # face == 5
    # Index face in positive z-direction
    boundaries.node_indices[boundary_id] = (:i, :j, :end)
  end

  return boundaries
end

function init_boundaries!(boundaries, mesh::P4estMesh{3})
  # Let p4est iterate over all interfaces and call init_boundaries_iter_face
  iter_face_c = @cfunction(init_boundaries_iter_face, Cvoid, (Ptr{p8est_iter_face_info_t}, Ptr{Cvoid}))
  user_data = [boundaries, 1, mesh]

  iterate_faces(mesh.p4est, iter_face_c, user_data)

  return boundaries
end
