/*
 * Copyright (c) 2022-2023, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#pragma once

#include <cuspatial/geometry/vec_2d.hpp>
#include <cuspatial/geometry/vec_3d.hpp>
#include <cuspatial/geometry_collection/multipoint_ref.cuh>
#include <cuspatial/traits.hpp>

#include <cuspatial/detail/utility/floating_point.cuh>
#include <cuspatial/geometry/polygon_ref.cuh>

#include <thrust/swap.h>

namespace cuspatial {
namespace detail {

/**
 * @brief Test if a point is inside a polygon.
 *
 * Implemented based on Eric Haines's crossings-multiply algorithm:
 * See "Crossings test" section of http://erich.realtimerendering.com/ptinpoly/
 * The improvement in addenda is also adopted to remove divisions in this kernel.
 *
 * @tparam T type of coordinate
 * @tparam PolygonRef polygon_ref type
 * @param test_point point to test for point in polygon
 * @param polygon polygon to test for point in polygon
 * @return boolean to indicate if point is inside the polygon.
 * `false` if point is on the edge of the polygon.
 */
template <typename T, class PolygonRef>
__device__ inline bool is_point_in_polygon(vec_2d<T> const& test_point, PolygonRef const& polygon)
{
  bool point_is_within = false;
  bool point_on_edge   = false;
  for (auto ring : polygon) {
    auto last_segment = ring.segment(ring.num_segments() - 1);

    auto b       = last_segment.v2;
    bool y0_flag = b.y > test_point.y;
    bool y1_flag;
    auto ring_points = multipoint_ref{ring.point_begin(), ring.point_end()};
    for (vec_2d<T> a : ring_points) {
      // for each line segment, including the segment between the last and first vertex
      T run  = b.x - a.x;
      T rise = b.y - a.y;

      // Points on the line segment are the same, so intersection is impossible.
      // This is possible because we allow closed or unclosed polygons.
      T constexpr zero = 0.0;
      if (float_equal(run, zero) && float_equal(rise, zero)) continue;

      T rise_to_point = test_point.y - a.y;
      T run_to_point  = test_point.x - a.x;

      // point-on-edge test
      bool is_colinear = float_equal(run * rise_to_point, run_to_point * rise);
      if (is_colinear) {
        T minx = a.x;
        T maxx = b.x;
        if (minx > maxx) thrust::swap(minx, maxx);
        if (minx <= test_point.x && test_point.x <= maxx) {
          point_on_edge = true;
          break;
        }
      }

      y1_flag = a.y > test_point.y;
      if (y1_flag != y0_flag) {
        // Transform the following inequality to avoid division
        //  test_point.x < (run / rise) * rise_to_point + a.x
        auto lhs = (test_point.x - a.x) * rise;
        auto rhs = run * rise_to_point;
        if (lhs < rhs != y1_flag) { point_is_within = not point_is_within; }
      }
      b       = a;
      y0_flag = y1_flag;
    }
    if (point_on_edge) {
      point_is_within = false;
      break;
    }
  }

  return point_is_within;
}

/** @brief check if p3 is on the left side of the arc that is
 * defined but p1 and p2
 * @note: T can be float or double and T4 can be float4 or double4
 * @param p1: first point of an arc
 * @param p2: second point af an arc
 * @param p3: a point to check
 * @return bool
 */
template <typename T>
__device__ bool is_left(vec_3d<T> const p1, vec_3d<T> const& p2, vec_3d<T> const& p3)
{
  vec_3d<T> po = {0, 0, 0};
  auto ao      = po - p1;
  auto ab      = p2 - p1;
  auto ac      = p3 - p1;
  auto aoxab   = cross_product(ao, ab);
  auto w       = dot(aoxab, ac);

  return w > 0;
}

/** @brief check if two arcs, defined with (p1, p2) and (p3, p4)
 * intersects (true or not)
 * @note: T can be float or double and T4 can be float4 or double4
 * @param p1: first point of first arc
 * @param p2: second point af first arc
 * @param p3: first point of second arc
 * @param p4: second point af second arc
 * @return bool
 */
template <typename T>
__device__ bool is_intersecting(vec_3d<T> const& p1,
                                vec_3d<T> const& p2,
                                vec_3d<T> const& p3,
                                vec_3d<T> const& p4)
{
  auto p1left = is_left(p3, p4, p1);
  auto p2left = is_left(p3, p4, p2);
  auto p3left = is_left(p1, p2, p3);
  auto p4left = is_left(p1, p2, p4);

  auto alpha = dot(p1, p3);

  return (p1left != p2left) && (p3left != p4left) && alpha > 0;
}

/**
 * @brief Test if a point is inside a polygon.
 *
 * Implemented based on Eric Haines's crossings-multiply algorithm:
 * See "Crossings test" section of http://erich.realtimerendering.com/ptinpoly/
 * The improvement in addenda is also adopted to remove divisions in this kernel.
 *
 * @tparam T type of coordinate
 * @tparam PolygonRef polygon_ref type
 * @param test_point point to test for point in polygon
 * @param polygon polygon to test for point in polygon
 * @return boolean to indicate if point is inside the polygon.
 * `false` if point is on the edge of the polygon.
 */
template <typename T, class PolygonRef>
__device__ inline bool is_point_in_polygon_spherical(vec_3d<T> const& test_point,
                                                     PolygonRef const& polygon)
{
  bool check = false, left_check = false, point_is_within = false;
  vec_3d<T> check_point;
  for (auto ring : polygon) {
    auto ring_points = multipoint_ref{ring.point_begin(), ring.point_end()};
    vec_3d<T> b      = ring_points[ring.num_segments()];
    for (vec_3d<T> a : ring_points) {
      if (!check) {
        left_check  = is_left(b, a, test_point);
        check_point = a;
      } else {
        if (is_intersecting(b, a, test_point, check_point)) {
          point_is_within = not point_is_within;
        }
      }
      b = a;
    }
  }
  return point_is_within == left_check;
}

}  // namespace detail
}  // namespace cuspatial
