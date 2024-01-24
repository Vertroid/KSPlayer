//
//  Shaders.metal
#include <metal_stdlib>
using namespace metal;

struct CustomData {
    int stereoMode;
    uint frameCounter;
};

struct VertexIn
{
    float4 pos [[attribute(0)]];
    float2 uv [[attribute(1)]];
};

struct VertexOut {
    float4 renderedCoordinate [[position]];
    float2 textureCoordinate;
};

inline half4 gammaToLinear(half4 col) {
    half a = 0.305306011h;  // 使用 'h' 后缀来指明half类型的字面量
    half b = 0.682171111h;
    half c = 0.012522878h;

    // 只对颜色的RGB分量进行计算，保留Alpha分量不变
    half3 colRGB = col.rgb;
    colRGB = colRGB * (colRGB * (colRGB * a + b) + c);

    return half4(colRGB, col.a); // 重新构建包含修改后的RGB分量和原始Alpha分量的half4
}

vertex VertexOut mapTexture(VertexIn input [[stage_in]]) {
    VertexOut outVertex;
    outVertex.renderedCoordinate = input.pos;
    outVertex.textureCoordinate = input.uv;
    return outVertex;
}

vertex VertexOut mapSphereTexture(VertexIn input [[stage_in]], constant float4x4& uniforms [[ buffer(2) ]]) {
    VertexOut outVertex;
    outVertex.renderedCoordinate = uniforms * input.pos;
    outVertex.textureCoordinate = input.uv;
    return outVertex;
}

fragment half4 displayTexture(VertexOut mappingVertex [[ stage_in ]],
                              texture2d<half, access::sample> texture [[ texture(0) ]],
                              constant CustomData& customData [[ buffer(3) ]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);

    bool isLeftEye = (customData.frameCounter % 2) == 0;
    float2 adjustedTexCoord = mappingVertex.textureCoordinate;
    if (customData.stereoMode == 1) {
        if (isLeftEye) {
            adjustedTexCoord.x = adjustedTexCoord.x * 0.5;
        } else {
            adjustedTexCoord.x = adjustedTexCoord.x * 0.5 + 0.5;
        }
    }
    
    half4 col = half4(texture.sample(s, adjustedTexCoord));
    half4 finalCol = gammaToLinear(col);
    if (adjustedTexCoord.x < 0.0 || adjustedTexCoord.x > 1.0) {
        finalCol = half4(0.0, 0.0, 0.0, 1.0);
    }
    return finalCol;
}

fragment half4 displayYUVTexture(VertexOut in [[ stage_in ]],
                                  texture2d<half> yTexture [[ texture(0) ]],
                                  texture2d<half> uTexture [[ texture(1) ]],
                                  texture2d<half> vTexture [[ texture(2) ]],
                                  sampler textureSampler [[ sampler(0) ]],
                                  constant float3x3& yuvToBGRMatrix [[ buffer(0) ]],
                                  constant float3& colorOffset [[ buffer(1) ]],
                                  constant uchar3& leftShift [[ buffer(2) ]],
                                  constant CustomData& customData [[ buffer(3) ]])
{
    half3 yuv;
    bool isLeftEye = (customData.frameCounter % 2) == 0;
    float2 adjustedTexCoord = in.textureCoordinate;
    if (customData.stereoMode == 1) {
        if (isLeftEye) {
            adjustedTexCoord.x = adjustedTexCoord.x * 0.5;
        } else {
            adjustedTexCoord.x = adjustedTexCoord.x * 0.5 + 0.5;
        }
    }
    yuv.x = yTexture.sample(textureSampler, adjustedTexCoord).r;
    yuv.y = uTexture.sample(textureSampler, adjustedTexCoord).r;
    yuv.z = vTexture.sample(textureSampler, adjustedTexCoord).r;
    half4 col = half4(half3x3(yuvToBGRMatrix)*(yuv*half3(leftShift)+half3(colorOffset)), 1);
    half4 finalCol = gammaToLinear(col);
            if (adjustedTexCoord.x < 0.0 || adjustedTexCoord.x > 1.0) {
                finalCol = half4(0.0, 0.0, 0.0, 1.0);
            }
//    if (customData.displayMode == 3) {

//    }
    return finalCol;
}


fragment half4 displayNV12Texture(VertexOut in [[ stage_in ]],
                                  texture2d<half> lumaTexture [[ texture(0) ]],
                                  texture2d<half> chromaTexture [[ texture(1) ]],
                                  sampler textureSampler [[ sampler(0) ]],
                                  constant float3x3& yuvToBGRMatrix [[ buffer(0) ]],
                                  constant float3& colorOffset [[ buffer(1) ]],
                                  constant uchar3& leftShift [[ buffer(2) ]],
                                  constant CustomData& customData [[ buffer(3) ]])
{
    half3 yuv;
    bool isLeftEye = (customData.frameCounter % 2) == 0;
    float2 adjustedTexCoord = in.textureCoordinate;
    if (customData.stereoMode == 1) {
        if (isLeftEye) {
            adjustedTexCoord.x = adjustedTexCoord.x * 0.5;
        } else {
            adjustedTexCoord.x = adjustedTexCoord.x * 0.5 + 0.5;
        }
    }
    yuv.x = lumaTexture.sample(textureSampler, adjustedTexCoord).r;
    yuv.yz = chromaTexture.sample(textureSampler, adjustedTexCoord).rg;
    half4 col = half4(half3x3(yuvToBGRMatrix)*(yuv*half3(leftShift)+half3(colorOffset)), 1);
    half4 finalCol = gammaToLinear(col);
    if (adjustedTexCoord.x < 0.0 || adjustedTexCoord.x > 1.0) {
        finalCol = half4(0.0, 0.0, 0.0, 1.0);
    }
    return finalCol;
}



