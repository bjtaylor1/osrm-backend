/*

Copyright (c) 2013, Project OSRM, Dennis Luxen, others
All rights reserved.

Redistribution and use in source and binary forms, with or without modification,
are permitted provided that the following conditions are met:

Redistributions of source code must retain the above copyright notice, this list
of conditions and the following disclaimer.
Redistributions in binary form must reproduce the above copyright notice, this
list of conditions and the following disclaimer in the documentation and/or
other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

*/

#ifndef RAW_ROUTE_DATA_H
#define RAW_ROUTE_DATA_H

#include "../DataStructures/PhantomNodes.h"
#include "../DataStructures/TurnInstructions.h"
#include "../typedefs.h"

#include <osrm/Coordinate.h>

#include <limits>

#include <vector>

struct PathData
{
    PathData()
        : node(std::numeric_limits<unsigned>::max()), name_id(std::numeric_limits<unsigned>::max()),
          segment_duration(std::numeric_limits<unsigned>::max()),
          turn_instruction(std::numeric_limits<TurnInstruction>::max())
    {
    }

    PathData(NodeID no, unsigned na, unsigned tu, unsigned dur)
        : node(no), name_id(na), segment_duration(dur), turn_instruction(tu)
    {
    }
    NodeID node;
    unsigned name_id;
    unsigned segment_duration;
    TurnInstruction turn_instruction;
};

struct RawRouteData
{
    std::vector<std::vector<PathData>> unpacked_path_segments;
    std::vector<PathData> unpacked_alternative;
    std::vector<PhantomNodes> segment_end_coordinates;
    std::vector<FixedPointCoordinate> raw_via_node_coordinates;
    unsigned check_sum;
    int shortest_path_length;
    int alternative_path_length;
    bool source_traversed_in_reverse;
    bool target_traversed_in_reverse;
    bool alt_source_traversed_in_reverse;
    bool alt_target_traversed_in_reverse;

    RawRouteData()
        : check_sum(std::numeric_limits<unsigned>::max()),
          shortest_path_length(std::numeric_limits<int>::max()),
          alternative_path_length(std::numeric_limits<int>::max()),
          source_traversed_in_reverse(false), target_traversed_in_reverse(false),
          alt_source_traversed_in_reverse(false), alt_target_traversed_in_reverse(false)
    {
    }
};

#endif // RAW_ROUTE_DATA_H
