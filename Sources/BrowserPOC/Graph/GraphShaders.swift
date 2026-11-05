import Foundation

/// Metal shaders for the graph, compiled at runtime because SwiftPM executables don't bundle
/// `.metal` files. World coordinates have y pointing down, like the view.
enum GraphShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float2 viewSize;     // points
        float2 center;       // world point at the middle of the view
        float scale;         // points per world unit
        float lineWidth;     // points
        float arrowSize;     // points
        int hovered;         // -1 for none
        float4 ringColor;
        float4 hoverRingColor;
        float4 labelColor;
    };

    struct NodeStyle {
        float4 color;
        float radius;        // world units
        float alpha;
        float ring;          // 1 draws the "you are here" ring
        float hollow;        // 1 draws an outline instead of a disc
    };

    struct EdgeData {
        uint a;
        uint b;
        uint type;           // index into the colour table; bit 8 marks a directed edge
        float weight;
    };

    struct LabelData {
        float2 world;
        float2 offset;       // points, from the node centre to the label's top middle
        float2 size;         // points
        float4 uv;           // x0, y0, x1, y1 in the atlas
        float alpha;
        float pad;
    };

    static float2 toScreen(float2 w, constant Uniforms& u) {
        return (w - u.center) * u.scale + u.viewSize * 0.5;
    }

    static float4 toClip(float2 s, constant Uniforms& u) {
        return float4(s.x / u.viewSize.x * 2.0 - 1.0, 1.0 - s.y / u.viewSize.y * 2.0, 0.0, 1.0);
    }

    // MARK: Edges

    struct EdgeOut {
        float4 position [[position]];
        float across;        // points from the centre line
        float halfWidth;
        float4 color;
    };

    vertex EdgeOut edgeVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                              constant Uniforms& u [[buffer(0)]],
                              const device float2* pos [[buffer(1)]],
                              const device NodeStyle* style [[buffer(2)]],
                              const device EdgeData* edges [[buffer(3)]],
                              constant float4* colors [[buffer(4)]]) {
        EdgeData e = edges[iid];
        float2 p0 = toScreen(pos[e.a], u);
        float2 p1 = toScreen(pos[e.b], u);
        float2 d = p1 - p0;
        float len = length(d);
        float2 dir = len > 0.0001 ? d / len : float2(1.0, 0.0);
        float2 nrm = float2(-dir.y, dir.x);
        float hw = max(u.lineWidth, 0.6) * 0.5;
        float pad = hw + 1.0;
        int corner = int(vid);
        // Two triangles: 0 1 2, 2 1 3.
        int c = corner < 3 ? corner : (corner == 3 ? 2 : (corner == 4 ? 1 : 3));
        float2 along = (c == 0 || c == 2) ? p0 : p1;
        float side = (c == 0 || c == 1) ? -1.0 : 1.0;
        EdgeOut o;
        o.position = toClip(along + nrm * pad * side, u);
        o.across = pad * side;
        o.halfWidth = hw;
        float4 col = colors[e.type & 0xFF];
        float a = min(style[e.a].alpha, style[e.b].alpha);
        bool lit = u.hovered >= 0 && (int(e.a) == u.hovered || int(e.b) == u.hovered);
        float boost = lit ? 2.2 : 1.0;
        // Thin lines fade instead of shrinking below a pixel.
        float thin = min(1.0, u.lineWidth / 0.6);
        col.a = min(1.0, col.a * boost * (0.65 + 0.35 * e.weight)) * a * thin;
        o.color = col;
        return o;
    }

    fragment float4 edgeFragment(EdgeOut in [[stage_in]]) {
        float cov = clamp(in.halfWidth - abs(in.across) + 0.5, 0.0, 1.0);
        float4 c = in.color;
        c.a *= cov;
        return float4(c.rgb * c.a, c.a);
    }

    // MARK: Arrows

    struct ArrowOut {
        float4 position [[position]];
        float4 color;
    };

    vertex ArrowOut arrowVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                constant Uniforms& u [[buffer(0)]],
                                const device float2* pos [[buffer(1)]],
                                const device NodeStyle* style [[buffer(2)]],
                                const device EdgeData* edges [[buffer(3)]],
                                constant float4* colors [[buffer(4)]]) {
        EdgeData e = edges[iid];
        float2 p0 = toScreen(pos[e.a], u);
        float2 p1 = toScreen(pos[e.b], u);
        float2 d = p1 - p0;
        float len = length(d);
        float2 dir = len > 0.0001 ? d / len : float2(1.0, 0.0);
        float2 nrm = float2(-dir.y, dir.x);
        float rb = max(style[e.b].radius * u.scale, 1.5) + 1.5;
        float s = u.arrowSize;
        float2 tip = p1 - dir * rb;
        float2 base = tip - dir * s;
        float2 v = vid == 0 ? tip : (vid == 1 ? base + nrm * s * 0.45 : base - nrm * s * 0.45);
        ArrowOut o;
        o.position = toClip(v, u);
        float4 col = colors[e.type & 0xFF];
        float a = min(style[e.a].alpha, style[e.b].alpha);
        bool directed = (e.type & 0x100) != 0;
        bool roomy = len > rb + style[e.a].radius * u.scale + s * 1.5;
        bool lit = u.hovered >= 0 && (int(e.a) == u.hovered || int(e.b) == u.hovered);
        col.a = (directed && roomy) ? min(1.0, col.a * (lit ? 2.4 : 1.6)) * a : 0.0;
        o.color = col;
        return o;
    }

    fragment float4 arrowFragment(ArrowOut in [[stage_in]]) {
        return float4(in.color.rgb * in.color.a, in.color.a);
    }

    // MARK: Nodes

    struct NodeOut {
        float4 position [[position]];
        float2 local;        // points from the centre
        float radius;        // points
        float ring;
        float hollow;
        float hovered;
        float4 color;
    };

    vertex NodeOut nodeVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                              constant Uniforms& u [[buffer(0)]],
                              const device float2* pos [[buffer(1)]],
                              const device NodeStyle* style [[buffer(2)]]) {
        NodeStyle st = style[iid];
        float2 c = toScreen(pos[iid], u);
        float r = max(st.radius * u.scale, 1.6);
        bool hov = int(iid) == u.hovered;
        float extent = r + ((st.ring > 0.5 || hov) ? 5.0 : 1.5);
        int corner = int(vid);
        int k = corner < 3 ? corner : (corner == 3 ? 2 : (corner == 4 ? 1 : 3));
        float2 off = float2((k & 1) ? extent : -extent, (k & 2) ? extent : -extent);
        NodeOut o;
        o.position = toClip(c + off, u);
        o.local = off;
        o.radius = r;
        o.ring = st.ring;
        o.hollow = st.hollow;
        o.hovered = hov ? 1.0 : 0.0;
        o.color = float4(st.color.rgb, st.color.a * st.alpha);
        return o;
    }

    fragment float4 nodeFragment(NodeOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
        float d = length(in.local);
        float4 c = in.color;
        float fill = clamp(in.radius - d + 0.5, 0.0, 1.0);
        if (in.hollow > 0.5) {
            float edge = clamp(1.0 - abs(d - (in.radius - 0.6)) + 0.4, 0.0, 1.0);
            fill = edge;
        }
        float4 out = float4(c.rgb * c.a * fill, c.a * fill);
        if (in.ring > 0.5 || in.hovered > 0.5) {
            float4 rc = in.hovered > 0.5 ? u.hoverRingColor : u.ringColor;
            float rr = in.radius + 2.6;
            float ringCov = clamp(0.75 - abs(d - rr) + 0.5, 0.0, 1.0) * rc.a * max(c.a, 0.35);
            out = out + float4(rc.rgb * ringCov, ringCov) * (1.0 - out.a);
        }
        return out;
    }

    // MARK: Labels

    struct LabelOut {
        float4 position [[position]];
        float2 uv;
        float alpha;
    };

    vertex LabelOut labelVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                constant Uniforms& u [[buffer(0)]],
                                const device LabelData* labels [[buffer(1)]]) {
        LabelData l = labels[iid];
        float2 top = toScreen(l.world, u) + l.offset;
        int corner = int(vid);
        int k = corner < 3 ? corner : (corner == 3 ? 2 : (corner == 4 ? 1 : 3));
        float2 p = float2(top.x + ((k & 1) ? 0.5 : -0.5) * l.size.x, top.y + ((k & 2) ? l.size.y : 0.0));
        // Snap to whole points so text stays crisp.
        p = floor(p * 2.0 + 0.5) / 2.0;
        LabelOut o;
        o.position = toClip(p, u);
        o.uv = float2((k & 1) ? l.uv.z : l.uv.x, (k & 2) ? l.uv.w : l.uv.y);
        o.alpha = l.alpha;
        return o;
    }

    fragment float4 labelFragment(LabelOut in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                                  texture2d<float> atlas [[texture(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float cov = atlas.sample(s, in.uv).r;
        float a = cov * in.alpha * u.labelColor.a;
        return float4(u.labelColor.rgb * a, a);
    }
    """
}
