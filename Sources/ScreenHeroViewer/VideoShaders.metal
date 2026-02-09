// VideoShaders.metal
// Metal shaders for zero-copy video display

#include <metal_stdlib>
using namespace metal;

// Vertex structure for fullscreen quad
struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// Fullscreen quad vertex shader
// Uses vertex ID to generate positions without requiring a vertex buffer
vertex VertexOut videoVertexShader(uint vertexID [[vertex_id]]) {
    // Generate fullscreen quad vertices
    // Vertex IDs 0-3 map to corners: bottom-left, bottom-right, top-left, top-right
    float2 positions[4] = {
        float2(-1.0, -1.0),  // bottom-left
        float2( 1.0, -1.0),  // bottom-right
        float2(-1.0,  1.0),  // top-left
        float2( 1.0,  1.0)   // top-right
    };

    // Texture coordinates (flipped Y for correct orientation)
    float2 texCoords[4] = {
        float2(0.0, 1.0),  // bottom-left
        float2(1.0, 1.0),  // bottom-right
        float2(0.0, 0.0),  // top-left
        float2(1.0, 0.0)   // top-right
    };

    VertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.texCoord = texCoords[vertexID];
    return out;
}

// Fragment shader that samples the video texture
fragment float4 videoFragmentShader(VertexOut in [[stage_in]],
                                     texture2d<float> videoTexture [[texture(0)]]) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    float4 color = videoTexture.sample(textureSampler, in.texCoord);

    // BGRA to RGBA conversion (if needed - VideoToolbox outputs BGRA)
    // The texture format should handle this, but swap if colors look wrong
    return float4(color.rgb, 1.0);
}
