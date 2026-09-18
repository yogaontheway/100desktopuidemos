import Combine
import SwiftUI
import MetalKit
import Metal
import simd
import Foundation
import UniformTypeIdentifiers

/* ==================================================================
   BLACK HOLE — GRAVITY RECYCLE BIN  (v2 — filament build)

   核心观感 (单文件 ~3.0s 生命周期):
     S0 溶解 0.00-0.45s  卡片潮汐拉伸 → 提亮 → 模糊 → 交给 GPU
     S1 缠绕 0.45-1.80s  化作 3 股光丝, 沿自转方向螺旋内旋 (开普勒: 越内越快)
     S2 成盘 1.80-2.40s  丝头抵达 ISCO, 最后一闪; 轨迹沉淀成完整吸积盘
     S3 消散 2.40-3.00s  盘外缘向内坍缩 + 亮度衰减, 归于宁静 (只剩光子环)

   与 v1 的关键差异:
     - "丝"是真的丝: 参数化螺旋曲线的屏幕空间距离场, 连续可追踪, 不是扫描条纹
     - 自转方向统一: 所有角向演化 (丝螺旋 / 盘物质流 / 透镜旋转) 共用 spin 符号
     - 卡片 → 丝 在 0.45s 处无缝交接, 不再是"卡片缩小消失 + 盘凭空亮起"两段戏
     - 多普勒 beaming + 远侧透镜上翘 (Gargantua 上弧), 盘有明确的正反转感
   ================================================================== */

// MARK: - Metal Shader (MSL)

let metalShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float2 resolution;
    float  time;
    float  spin;          // 自转方向 +1 / -1 (所有角向演化的公共符号)
    float2 center;
    float  diskIncline;   // cos(倾角)
    float  rotation;      // 透镜旋转相位
    float4 guide;         // z: 捕获半径(屏幕高度单位) / w: 透明度
    float4 filTime;       // xyz: 3 个吞噬事件的起始时刻 (<= -900 表示该槽空闲)
    float4 filR0;         // xyz: 初始半径 (屏幕高度单位)
    float4 filA0;         // xyz: 初始方位角
    float4 filC0;         // 事件 0 的 rgb + 强度
    float4 filC1;
    float4 filC2;
};

struct VOut {
    float4 pos [[position]];
    float2 uv;
};

vertex VOut vs_full(uint vid [[vertex_id]]) {
    float2 q = float2(((vid << 1u) & 2u), (vid & 2u));
    VOut o;
    o.pos = float4(q * 2.0 - 1.0, 0.0, 1.0);
    o.uv  = q;               // 大三角形: 屏幕内插值 uv ∈ [0,1], y 向上为正
    return o;
}

// ---------- 几何常量 (屏幕高度单位) ----------
constant float B      = 0.20;    // 光子环半径
constant float Rsh    = 0.19;    // 视界阴影半径
constant float RISCO  = 0.265;   // 吸积盘内缘 (最内稳定圆轨道)
constant float DUR    = 3.0;     // 单次吞噬总时长
constant float OMEGA  = 19.0;    // 丝的累计缠绕弧度 (≈3 圈)

// ---------- 观感调参旋钮 (与 blackhole_preview.html 的滑块一一对应) ----------
// 在预览页调出满意手感后, 点"复制参数"直接覆盖这里
constant float FIL_GAIN    = 2.6;   // 丝亮度
constant float SED_GAIN    = 0.34;  // 盘实体 (丝的沉积)
constant float WIDTH_SCALE = 1.0;   // 丝宽倍率
constant float SPREAD      = 0.072; // 丝→盘的黏性扩散率

// ---------- 噪声 ----------
float hash21(float2 p) {
    p = fract(p * float2(234.34, 435.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}
float vnoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}
float fbm(float2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 5; i++) {
        v += a * vnoise(p);
        p = p * 2.03 + float2(0.7, 1.3);
        a *= 0.5;
    }
    return v;
}
// 域扭曲 fbm → 云絮/漩涡, 用作吸积等离子流的湍流纹理
float plasma(float2 p, float time) {
    float2 q = p + 0.9 * float2(fbm(p * 1.6 + time * 0.12),
                                fbm(p * 1.6 + time * 0.12 + 3.7));
    return fbm(q * 2.1 + time * 0.25);
}

// ---------- 程序化深空背景: 四层视差星场 ----------
float stars(float2 uv, float aspect, float cell, float seed, float time, float2 center) {
    float2 par = 0.05 * (center - 0.5);
    float2 g = uv * float2(aspect, 1.0) * cell + par * cell + float2(seed);
    float2 id = floor(g);
    float2 f = fract(g);
    float h = hash21(id + float2(seed));
    float bright = step(0.952, h);
    float mega   = step(0.991, h);
    float2 sp = float2(hash21(id + 1.7), hash21(id + 3.3));
    float d = length(f - sp);
    float c1 = exp(-d * d * 1400.0);
    float c2 = exp(-d * d * 500.0);
    float halo = exp(-d * d * 130.0) * 0.45;
    float tw = 0.7 + 0.3 * sin(time * (0.8 + 0.5 * h) + h * 37.0);
    float s = mega * (c1 + c2 * 0.5 + halo * 0.35) + bright * (c2 * 0.35);
    return s * tw;
}
float starField(float2 uv, float aspect, float time, float2 center) {
    float t = 0.0;
    t += stars(uv, aspect,  6.0, 0.0, time, center) * 0.9;
    t += stars(uv, aspect, 10.0, 2.3, time, center) * 1.0;
    t += stars(uv, aspect, 19.0, 3.7, time, center) * 1.2;
    t += stars(uv, aspect, 42.0, 7.1, time, center) * 1.5;
    return t;
}
float3 spaceBG(float2 uv, float time, float2 center, float aspect) {
    float3 col = float3(0.0);
    float s = starField(uv, aspect, time, center);
    col += float3(0.80, 0.86, 1.00) * s * 0.9;
    return col;
}

// ---------- 色调映射 ----------
float3 aces(float3 x) {
    return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0);
}

// 黑体辐射: 0 = 外围暗红, 0.5 = 金黄, 1 = 核心白热
float3 blackbodyColor(float t) {
    float3 col = float3(0.0);
    col.r = smoothstep(0.0, 0.5, t);
    col.g = smoothstep(0.2, 0.8, t) * 0.7;
    col.b = smoothstep(0.6, 1.0, t);
    return col;
}

// ==================================================================
//  盘面几何: 倾角椭圆投影 (丝用正变换, 盘用反变换, 二者一致)
// ==================================================================

float2 screenToDisk(float2 d0, float cosI) {
    return float2(d0.x, d0.y / max(cosI, 0.12));
}

// ==================================================================
//  统一物质流场: 丝与盘是同一种物质的两种状态
//  物理图像: 卡片在 (r0,a0) 被引力撕裂 → 物质沿螺旋下落 → 落定后被黏性扩散摊开
//    age = uH - s   物质落定后经过的时间
//    age 小 → 窄而炽亮 → 看见的是「丝」
//    age 大 → 被摊宽、连成一片 → 看见的是「盘」
//  盘不再是独立图层, 它是丝的时空积分 —— 这是"融合"的根源
//  由细到粗: 流带头向内推进, 沉积区 [r_head, r0] 跨度随 u 变宽
//  再到细:   消散期早落定的外圈先塌, 外缘内收, 整体衰减至零
// ==================================================================

void renderStream(float2 d0, float t, float cosI, float spin,
                  float t0, float r0, float a0, float3 fcol,
                  thread float3 &farC, thread float3 &nearC) {
    float u = (t - t0) / DUR;
    if (u <= 0.0 || u >= 1.0) return;

    float sinI = sqrt(max(1.0 - cosI * cosI, 0.0));
    float birth = smoothstep(0.0, 0.035, u);
    float death = 1.0 - smoothstep(0.80, 1.0, u);
    float env = birth * death;
    if (env <= 0.002) return;

    float2 pd = screenToDisk(d0, cosI);
    float rdp = length(pd);
    float r0c = max(r0, RISCO * 1.02);
    // 远界: halo 已完全为零, 纯性能裁剪 (真正的软边界在下面 clip 因子里)
    if (rdp > r0c * 2.0 || rdp < Rsh * 0.40) return;
    // 软裁剪: 物质在边界处平滑衰减到零 —— far 侧透镜逆变换会把圆形边界
    // 拉成近直线, 硬 return 会在那里切出竖直亮边, 必须用渐变归零
    float clipOut = 1.0 - smoothstep(r0c * 1.05, r0c * 1.34, rdp);
    float clipIn  = smoothstep(Rsh * 0.68, Rsh * 0.90, rdp);
    float phip = atan2(pd.y, pd.x);

    // 消散期: 早落定的外圈先塌 → 外缘内收 (由粗到细)
    float sMin = smoothstep(0.72, 1.0, u) * 0.90;
    // 撕裂: 多股从紧凑的一束, 逐渐被潮汐力扯散成带
    float spreadA = 0.020 + 0.080 * smoothstep(0.0, 0.40, u);

    float hotCore = 0.0, hotHalo = 0.0;   // 新物质 (丝): 锐利丝芯 / 扩散光晕分开统计
    float sedCore = 0.0, sedHalo = 0.0;   // 沉积物质 (盘的实体)

    for (int k = 0; k < 3; k++) {
        float fk = float(k);
        float aK = a0 + (fk - 1.0) * spreadA;
        float uH = clamp(u - fk * 0.05, 0.0, 1.0);
        if (uH <= 0.001) continue;
        float phiHead = OMEGA * pow(uH, 1.45);
        if (phiHead < 0.002) continue;

        // 像素相对角 (沿自转方向, mod 2π) — 每一圈是一个候选
        float raw = spin * (phip - aK);
        float dphi = fmod(fmod(raw, 2.0 * M_PI_F) + 2.0 * M_PI_F, 2.0 * M_PI_F);
        for (int c = 0; c < 5; c++) {
            float dt = dphi + 2.0 * M_PI_F * float(c);
            if (dt > phiHead) break;
            float s = pow(dt / OMEGA, 0.6897);       // 1/1.45 反解下落进度
            if (s > uH) continue;

            float age = uH - s;
            float rdU = mix(r0c, RISCO, pow(s, 1.55));
            float d = fabs(rdp - rdU);

            // 黏性扩散: 丝宽 ∝ sqrt(age) —— 丝与盘之间的连续桥; 头部收细成梢
            float w = WIDTH_SCALE * 0.0068 + SPREAD * sqrt(max(age, 0.0));
            w *= 1.0 - 0.72 * smoothstep(uH - 0.05, uH, s);
            // 核心 + 光晕双高斯: 核心定形; 光晕只跟随基础丝宽, 不跟随扩散
            float core = exp(-(d * d) / (w * w));
            float hw2 = 0.016 * WIDTH_SCALE + w * 0.75;
            float halo = exp(-(d * d) / (hw2 * hw2)) * 0.24;
            // 新落定: 炽热的丝; 丝头一段额外增亮, 末端自然收梢 (渐细渐灭, 无平切断口)
            // 注意 smoothstep 边界必须从小到大: 反写 (e0>e1) 是未定义行为,
            // Metal 碰巧算对, SwiftShader/部分驱动会硬切出放射状锯齿 (v16 教训)
            float tipFade = 1.0 - smoothstep(uH - 0.11, uH, s);
            float headBoost = (1.0 + 0.85 * smoothstep(uH - 0.14, uH, s)) * tipFade;
            // 最老的尾端 (s→0) 渐入归零: 第一圈未绕满时, 出生方位没有第二圈
            // 物质来衔接, 不渐隐会切出硬边 (丝与沉积都要渐隐)
            float tailFade = smoothstep(0.0, 0.34, s);
            // 消散期外圈内收: 软边界淡出 —— 硬 continue 会让残留线圈在
            // 交接方位以全亮度突然出现, 切出放射状锯齿亮边 (嵌合体成分之一)
            float sFade = smoothstep(sMin, sMin + 0.05, s);
            float hotG = exp(-age / 0.11) * headBoost * tailFade * sFade;
            hotCore += core * hotG;
            hotHalo += halo * hotG;
            float sed = smoothstep(0.0, 0.22, age) * (1.0 - 0.60 * smoothstep(0.30, 0.85, age)) * tailFade * sFade;
            sedCore += core * sed;
            sedHalo += halo * sed;
        }
    }
    // v17 统一遮挡场: 全方向按屏幕圆平滑压暗, 阴影轮廓只由这一条曲线决定。
    // 近侧按方位角豁免: 正前方 (sin < -0.55) 前景带自由穿过洞前;
    // 侧面/背面满挖河。权重在中线两侧都收敛到 1 —— 左右翼上下对称无缝,
    // 消除 v16 左/右中线处 farFade 圆 × 椭圆内缘夹出的矩形缺口
    float occ  = smoothstep(Rsh * 1.00, Rsh * 1.55, length(d0));
    float wOcc = smoothstep(-0.55, -0.05, sin(phip));
    float occN = mix(1.0, occ, wOcc);
    float hotAcc, sedAcc;
    hotAcc = (hotCore + hotHalo) * occN * clipOut * clipIn;
    sedAcc = (sedCore + sedHalo) * occN * clipOut * clipIn;
    if (hotAcc + sedAcc < 0.0025) return;

    // 颜色: 文件本色 → 被黑洞加热 → 黑体辐射 (越靠内越热)
    float heat = smoothstep(r0c, RISCO * 1.06, rdp);
    heat *= smoothstep(RISCO, RISCO * 1.30, rdp);   // 内缘降温归零: 边缘以文件本色渐隐, 消除贴边热线
    float3 col = mix(fcol, blackbodyColor(heat), smoothstep(0.0, 0.55, heat));
    col = mix(col, blackbodyColor(0.78 + 0.18 * heat), 0.30 * heat);

    float dopp = -spin * sinI * cos(phip);
    float beam = 1.0 + 2.2 * pow(max(dopp, 0.0), 1.4);
    float dim  = mix(1.0, 0.34, max(-dopp, 0.0));

    float sedS = 1.0 - exp(-sedAcc * 1.4);           // 饱和: 多圈叠加不过曝
    float3 c = col * (hotAcc * FIL_GAIN + sedS * SED_GAIN) * beam * dim * env;
    c *= mix(1.0, 0.55, smoothstep(0.10, 0.40, sin(phip)));   // 远侧压暗 (窗口外移: 两翼与近侧对称)
    // v17: farFade/moat 已被统一遮挡场 occ 覆盖 (farFade 的轮廓恰为阴影圆
    // —— rdp·kphi 恒等于屏幕圆半径 r —— 完全落在 occ 的 kill 区内),
    // 删除以减少洞周相贯轮廓数 (v16 的矩形缺口正是四条轮廓相夹所致)
    if (sin(phip) > 0.0) farC += c; else nearC += c;
}

fragment float4 fs(VOut in [[stage_in]],
                   constant Uniforms &u [[buffer(0)]]) {
    float aspect = u.resolution.x / max(u.resolution.y, 1.0);
    float2 uv = in.uv;

    float cosI = clamp(u.diskIncline, 0.10, 1.0);
    float spin = (u.spin >= 0.0) ? 1.0 : -1.0;

    float2 d0 = uv - u.center;
    d0.x *= aspect;
    float r   = length(d0);
    float ang = atan2(d0.y, d0.x);

    // 瞬态捕获引导圈 (仅拖拽靠近时, 极淡)
    float grc = 0.0;
    if (u.guide.w > 0.001) {
        grc = exp(-pow((r - u.guide.z) / 0.018, 2.0));
    }

    // 吞噬活跃度: 有物质坠落时, 光子环辉光/透镜星光才亮起 (盘本隐藏)
    // ringPulse: 光子环只在吞噬尾声 (盘将熄) 亮起, 盘消失后熄灭
    float activity = 0.0;
    float ringPulse = 0.0;
    for (int q = 0; q < 3; q++) {
        float tq = (q == 0) ? u.filTime.x : ((q == 1) ? u.filTime.y : u.filTime.z);
        if (tq <= -900.0) continue;
        float sq = u.time - tq;
        if (sq > 0.0 && sq < DUR) activity += 1.0 - sq / DUR;
        if (sq > 0.0 && sq < DUR * 1.12) {
            float p = sq / DUR;
            ringPulse += smoothstep(0.68, 0.86, p) * (1.0 - smoothstep(1.00, 1.10, p));
        }
    }
    float act = clamp(activity, 0.0, 1.0);
    float ringGlow = clamp(ringPulse, 0.0, 1.0);

    float inShadow = 1.0 - smoothstep(Rsh * 0.70, Rsh, r);
    float rw = max(fwidth(r), 1e-4);

    // ---- 引力透镜 (Schwarzschild 近似): 径向重映射 + 弧向弯折 ----
    float rr  = max(r, B * 0.42);
    float Rl  = rr + (B * B) / rr;
    float defl = 1.4 * (B * B) / (rr * rr);
    float la  = ang + (u.rotation * 0.9 + 0.35) * (B / rr) + sin(ang) * defl;
    float2 ldir = float2(cos(la), sin(la));
    float2 src = u.center + float2(ldir.x / aspect, ldir.y) * Rl;

    float3 col = spaceBG(src, u.time, u.center, aspect);
    col *= 0.25 + 0.75 * smoothstep(B * 0.70, B * 3.4, r);
    col *= 1.0 - inShadow;

    // 透镜聚光带 (Einstein 弧): v16 同步收窄, 与白圈一起贴着阴影外缘
    float lensB = exp(-pow((r - Rsh * 1.17) / (0.11 * B), 2.0)) * (1.0 - inShadow);
    float3 lensStar = float3(0.55, 0.65, 0.95);
    // 透镜星光: 只随光子环一起, 在吞噬尾声亮起 (盘快熄时) —— 平时保持隐藏
    col += lensStar * lensB * (0.02 + (0.08 + 0.28 * plasma(float2(d0.x * 1.8, d0.y * 1.8 + r * 0.5), u.time)) * ringGlow);

    // ---- 尾声白圈: 只保留宽柔的雾环 (haloRing, 爸爸要的那种);
    //      锐利的光子环已按要求移除, 不再出现。
    //      v16: 半径收到 Rsh*1.10、宽度减半 —— 白圈要比吸积盘小,
    //      紧贴黑洞表面 (原 B*1.16 太靠外, 和蓝弧叠成大饼圈) ----
    float3 ringC = float3(1.08, 0.94, 0.72);
    col += ringC * exp(-pow((r - Rsh * 1.10) / (0.10 * B), 2.0)) * (1.0 - inShadow)
           * (0.004 + (0.012 + 0.055 * plasma(float2(d0.x * 1.5, d0.y * 1.5 + r * 0.3), u.time)) * ringGlow);

    // ---- 光丝 + 吸积盘 (远侧 / 近侧分开累积, 用于正确的遮挡关系) ----
    float3 farC  = float3(0.0);
    float3 nearC = float3(0.0);
    for (int i = 0; i < 3; i++) {
        float t0 = (i == 0) ? u.filTime.x : ((i == 1) ? u.filTime.y : u.filTime.z);
        if (t0 <= -900.0) continue;
        float since = u.time - t0;
        if (since <= 0.0 || since >= DUR) continue;

        float r0 = (i == 0) ? u.filR0.x : ((i == 1) ? u.filR0.y : u.filR0.z);
        float a0 = (i == 0) ? u.filA0.x : ((i == 1) ? u.filA0.y : u.filA0.z);
        float3 fc = (i == 0) ? u.filC0.rgb : ((i == 1) ? u.filC1.rgb : u.filC2.rgb);

        renderStream(d0, u.time, cosI, spin, t0, r0, a0, fc, farC, nearC);
    }

    col += farC;                    // 远侧: 已被透镜抬到视界之外
    float evMask = 1.0 - smoothstep(Rsh * 0.92, Rsh, r);
    col *= 1.0 - evMask;            // 视界绝对黑
    col += nearC;                   // 近侧: 从黑洞前方掠过, 遮挡视界下部

    // 引导圈 + 暗角
    col += float3(0.02, 0.02, 0.03) * grc * u.guide.w * 0.5;
    float2 sv = in.uv - 0.5;
    sv.x *= aspect;
    col *= 1.0 - 0.14 * pow(length(sv) * 1.5, 2.0);

    col = aces(col);
    col = pow(col, float3(1.0 / 2.2));
    return float4(col, 1.0);
}
"""

// MARK: - GPU 数据模型

struct RenderUniforms {
    var resolution:  SIMD2<Float> = .zero
    var time:        Float = 0
    var spin:        Float = 1
    var center:      SIMD2<Float> = SIMD2(0.5, 0.5)
    var diskIncline: Float = 0.62
    var rotation:    Float = 0
    var guide:       SIMD4<Float> = .zero
    var filTime:     SIMD4<Float> = SIMD4<Float>(-1000, -1000, -1000, 0)
    var filR0:       SIMD4<Float> = .zero
    var filA0:       SIMD4<Float> = .zero
    var filC0:       SIMD4<Float> = .zero
    var filC1:       SIMD4<Float> = .zero
    var filC2:       SIMD4<Float> = .zero
}

// MARK: - 光丝事件总线 (主线程写 / 渲染线程读)

struct FilamentSlot {
    var t0: Float = -1000      // 起始时刻 (shader 时钟)
    var r0: Float = 0          // 初始半径 (屏幕高度单位)
    var a0: Float = 0          // 初始方位角 (数学坐标, y 向上)
    var r:  Float = 0
    var g:  Float = 0
    var b:  Float = 0
}

/// 3 个槽位轮转复用。加锁以保证主线程 emit 与渲染线程 snapshot 之间不竞争。
final class FilamentBus: @unchecked Sendable {
    private let lock = NSLock()
    private var slots = Array(repeating: FilamentSlot(), count: 3)
    private var cursor = 0

    func emit(_ s: FilamentSlot) {
        lock.lock()
        slots[cursor % 3] = s
        cursor += 1
        lock.unlock()
    }

    func snapshot() -> (FilamentSlot, FilamentSlot, FilamentSlot) {
        lock.lock()
        defer { lock.unlock() }
        return (slots[0], slots[1], slots[2])
    }

    func clear() {
        lock.lock()
        slots = Array(repeating: FilamentSlot(), count: 3)
        cursor = 0
        lock.unlock()
    }
}

// MARK: - 文件卡片

struct FileCard: Identifiable {
    let id = UUID()
    let name: String
    let glyph: String
    let color: Color
    let rgb: SIMD3<Float>

    static func appearance(for url: URL) -> (String, Color, SIMD3<Float>) {
        let ext = url.pathExtension.lowercased()
        let (glyph, h, s, b) = categorized(ext)
        let rgb = hsvToRGB(h: Float(h), s: Float(s), v: Float(b))
        return (glyph, Color(red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z)), rgb)
    }

    private static func categorized(_ ext: String) -> (String, Double, Double, Double) {
        switch ext {
        case "mov", "mp4", "m4v", "avi", "mkv":
            return ("film.fill", 0.52, 0.75, 0.95)
        case "mp3", "wav", "m4a", "aac", "flac":
            return ("waveform", 0.75, 0.70, 0.95)
        case "pdf", "doc", "docx", "pages", "txt", "md", "rtfd":
            return ("doc.fill", 0.07, 0.80, 0.95)
        case "json", "plist", "yaml", "yml", "xml":
            return ("doc.text", 0.95, 0.80, 0.95)
        case "zip", "gz", "tar", "dmg", "7z":
            return ("archivebox.fill", 0.58, 0.70, 0.95)
        case "jpg", "jpeg", "png", "gif", "heic", "webp", "tiff":
            return ("photo.fill", 0.13, 0.70, 0.95)
        case "usdz", "obj", "stl", "scn", "dae":
            return ("cube.fill", 0.63, 0.70, 0.95)
        case "swift", "m", "mm", "c", "cpp", "h", "py", "js", "ts":
            return ("chevron.left.forwardslash.chevron.right", 0.60, 0.55, 0.90)
        default:
            return ("doc.fill", 0.60, 0.45, 0.80)
        }
    }

    private static func hsvToRGB(h: Float, s: Float, v: Float) -> SIMD3<Float> {
        let hh = (h.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * 6
        let i = Int(hh)
        let f = hh - Float(i)
        let p = v * (1 - s)
        let q = v * (1 - s * f)
        let t = v * (1 - s * (1 - f))
        switch i % 6 {
        case 0: return SIMD3(v, t, p)
        case 1: return SIMD3(q, v, p)
        case 2: return SIMD3(p, v, t)
        case 3: return SIMD3(p, q, v)
        case 4: return SIMD3(t, p, v)
        default: return SIMD3(v, p, q)
        }
    }
}

let cardPalette: [(String, String, Color, SIMD3<Float>)] = [
    ("Neptune.mov",      "photo",          .init(red: 0.30, green: 0.85, blue: 0.80), SIMD3(0.30, 0.85, 0.80)),
    ("Frequencies.wav",  "waveform.badge.mic", .init(red: 0.70, green: 0.40, blue: 1.00), SIMD3(0.70, 0.40, 1.00)),
    ("Sector-Report.pdf","doc.fill",       .init(red: 1.00, green: 0.55, blue: 0.20), SIMD3(1.00, 0.55, 0.20)),
    ("Invoice.Q3.json",  "doc.text",       .init(red: 0.95, green: 0.30, blue: 0.55), SIMD3(0.95, 0.30, 0.55)),
    ("Orbit Archive.zip","archivebox.fill",.init(red: 0.30, green: 0.75, blue: 0.95), SIMD3(0.30, 0.75, 0.95)),
    ("Nebula.usdz",      "cube.transparent",.init(red: 0.35, green: 0.50, blue: 1.00), SIMD3(0.35, 0.50, 1.00)),
]

struct SwallowState {
    let cardID: UUID
    let start: Date
    let r0: CGFloat          // 初始半径 (点, 卡片中心)
    let ang0: CGFloat        // 初始方位角 (数学坐标, y 向上, 卡片中心)
    let hr0: CGFloat         // 抓取点半径 (点, 近黑洞短边中点 = 光丝出生点)
    let ha0: CGFloat         // 抓取点方位角
}

struct ActiveDrag {
    let id: UUID
    let pos: CGPoint
    let nearHorizon: Bool      // 已进入吞噬轨道
    let withinReach: Bool      // 处于引力范围
    let strain: CGFloat        // 潮汐形变 0..1
}

// MARK: - 视图模型

@MainActor
final class BlackHoleModel: ObservableObject {
    let epoch = Date()
    let cardW: CGFloat = 132
    let cardH: CGFloat = 90
    let spacing: CGFloat = 158

    /// 卡片交给 GPU 之前的溶解时长 (S0)。此后 3 秒的戏全在 shader 里。
    let dissolveDuration: CGFloat = 0.60
    /// 黑洞自转方向: +1 逆时针 (与 shader 的 spin 保持一致)
    let spinSign: CGFloat = 1

    let bus = FilamentBus()

    @Published var deckOrder: [UUID] = []
    @Published var cardData: [UUID: FileCard] = [:]
    @Published var eatenCount = 0
    @Published var activeDrag: ActiveDrag?
    @Published var viewSize = CGSize(width: 800, height: 600)
    @Published var hasInteracted = false
    @Published var guideAlpha: Float = 0
    var lastPointer: CGPoint = CGPoint(x: 800, y: 600)

    var swallows: [UUID: SwallowState] = [:]

    let captureFraction: CGFloat = 0.38
    private let initialOrder: [UUID]

    init() {
        var order: [UUID] = []
        var data: [UUID: FileCard] = [:]
        for palette in cardPalette {
            let c = FileCard(name: palette.0, glyph: palette.1, color: palette.2, rgb: palette.3)
            order.append(c.id)
            data[c.id] = c
        }
        self.initialOrder = order
        self.deckOrder = order
        self.cardData = data
    }



    // ---- 几何 ----
    var holeCenter: CGPoint {
        CGPoint(x: viewSize.width * 0.5, y: viewSize.height * 0.5)
    }
    var captureRadius: CGFloat {
        min(viewSize.width, viewSize.height) * captureFraction
    }
    var captureReachUnits: Float {
        Float(captureRadius / max(viewSize.height, 1))
    }
    var visibleOrder: [UUID] {
        deckOrder.filter { !isFalling($0) }
    }
    func isFalling(_ id: UUID) -> Bool {
        swallows[id] != nil
    }
    func dockPosition(index: Int, size: CGSize) -> CGPoint {
        let n = CGFloat(index)
        let count = visibleOrder.count
        let totalW = CGFloat(count - 1) * spacing + cardW
        let startX = size.width * 0.5 - totalW * 0.5
        return CGPoint(x: startX + n * spacing + cardW * 0.5,
                       y: size.height * 0.88)
    }

    // ---- 坐标换算: SwiftUI (y 向下) → shader (y 向上, 屏幕高度单位) ----
    private func shaderPolar(from pos: CGPoint) -> (r: CGFloat, a: CGFloat) {
        let hole = holeCenter
        let h = max(viewSize.height, 1)
        let dx = (pos.x - hole.x) / h
        let dy = -(pos.y - hole.y) / h          // 翻转 y
        return (hypot(dx, dy), atan2(dy, dx))
    }

    // ---- 交互: 拖拽 ----
    func dragChanged(_ c: FileCard, location: CGPoint) {
        let hole = holeCenter
        let reach = captureRadius
        var p = location
        let d = hypot(p.x - hole.x, p.y - hole.y)
        var strain: CGFloat = 0
        var near = false
        if d < reach {
            let k = 0.35 * (1 - d / reach)
            p.x += (hole.x - p.x) * k
            p.y += (hole.y - p.y) * k
            strain = pow(clamp01(1 - d / reach), 2.5)
            near = d < reach * 0.68
        }
        let sd = hypot(p.x - hole.x, p.y - hole.y)
        guideAlpha = Float(clamp01(1 - sd / reach)) * 0.55
        activeDrag = ActiveDrag(id: c.id, pos: p, nearHorizon: near, withinReach: d < reach, strain: strain)
        hasInteracted = true
    }

    func dragEnded(_ c: FileCard) {
        guideAlpha = 0
        guard let drag = activeDrag, drag.id == c.id else {
            activeDrag = nil
            return
        }
        let hole = holeCenter
        let reach = captureRadius
        let d = hypot(drag.pos.x - hole.x, drag.pos.y - hole.y)
        if d < reach, !isFalling(c.id) {
            beginSwallow(c.id, from: drag.pos, rgb: c.rgb)
        }
        activeDrag = nil
    }

    // ---- 吞噬: 卡片记一笔(0.45s 溶解) + GPU 光丝记一笔(3.0s) ----
    func beginSwallow(_ id: UUID, from pos: CGPoint, rgb: SIMD3<Float>) {
        let polar = shaderPolar(from: pos)
        let r0pts = hypot(pos.x - holeCenter.x, pos.y - holeCenter.y)
        // 抓取点 = 近黑洞侧短边中点 —— 它同时是光丝的出生点:
        // 撕裂中被拉长的角每帧都钉在流线头部, 与吸积盘起点天然相连
        let axX: CGFloat = holeCenter.x > pos.x ? 1 : -1
        let headRest = CGPoint(x: pos.x + axX * cardW / 2, y: pos.y)
        let headPolar = shaderPolar(from: headRest)
        swallows[id] = SwallowState(cardID: id, start: Date(), r0: r0pts, ang0: polar.a,
                                    hr0: hypot(headRest.x - holeCenter.x, headRest.y - holeCenter.y),
                                    ha0: headPolar.a)

        var slot = FilamentSlot()
        slot.t0 = Float(Date().timeIntervalSince(epoch))
        slot.r0 = Float(headPolar.r)
        slot.a0 = Float(headPolar.a)
        slot.r = rgb.x
        slot.g = rgb.y
        slot.b = rgb.z
        bus.emit(slot)

        hasInteracted = true
    }

    func completeSwallow(_ id: UUID) {
        guard swallows.removeValue(forKey: id) != nil else { return }
        deckOrder.removeAll { $0 == id }
        eatenCount += 1
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
    }

    // 一步成型: 直接从外部 (Finder/桌面) 拖入真实文件, 落点即吞噬
    func swallowExternalFile(at point: CGPoint, url: URL) {
        let name = url.lastPathComponent
        let (glyph, color, rgb) = FileCard.appearance(for: url)
        let card = FileCard(name: name, glyph: glyph, color: color, rgb: rgb)
        cardData[card.id] = card
        deckOrder.append(card.id)
        beginSwallow(card.id, from: point, rgb: rgb)
        hasInteracted = true
    }

    // ---- RESET ----
    func reset() {
        swallows.removeAll()
        bus.clear()
        activeDrag = nil
        guideAlpha = 0
        eatenCount = 0
        deckOrder = initialOrder
    }
}

// MARK: - Helper

func clamp01(_ x: CGFloat) -> CGFloat { min(max(x, 0), 1) }
func smStep(_ e0: CGFloat, _ e1: CGFloat, _ x: CGFloat) -> CGFloat {
    let t = clamp01((x - e0) / (e1 - e0))
    return t * t * (3 - 2 * t)
}

// MARK: - Metal Renderer

final class BlackHoleRenderer: NSObject, MTKViewDelegate {
    unowned let model: BlackHoleModel
    private let bus: FilamentBus
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState

    /// 打开后会在吞噬过程中自动截图到 ~/Library/Caches/BlackHoleShots (调试用, 平时关闭)
    private let debugSnapshots = false
    #if os(macOS)
    private var shotIndex = 0
    private var pendingShots: [Double] = []
    private var lastEmitCount = 0
    #endif

    init?(model: BlackHoleModel) {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let q = dev.makeCommandQueue(),
              let lib = try? dev.makeLibrary(source: metalShaderSource, options: nil),
              let vs = lib.makeFunction(name: "vs_full"),
              let fs = lib.makeFunction(name: "fs")
        else { return nil }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vs
        desc.fragmentFunction = fs
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipe = try? dev.makeRenderPipelineState(descriptor: desc) else { return nil }

        self.device = dev
        self.queue = q
        self.pipeline = pipe
        self.model = model
        self.bus = model.bus
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let scale = view.window?.backingScaleFactor ?? 2
        let bw = view.bounds.width, bh = view.bounds.height
        guard bw.isFinite, bh.isFinite, bw > 0, bh > 0 else { return }
        let target = CGSize(width: bw * scale, height: bh * scale)
        if target != view.drawableSize {
            view.drawableSize = target
            return
        }
        guard let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let cb = queue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: pass)
        else { return }

        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        let t = Float(Date().timeIntervalSince(model.epoch))

        let size = CGSize(width: max(view.drawableSize.width, 1), height: max(view.drawableSize.height, 1))
        let ptr = model.lastPointerUV
        let base = SIMD2<Float>(0.5, 0.5)
        let lean = base + (ptr - base) * 0.05
        let wob = SIMD2<Float>(sin(t * 0.4) * 0.006, sin(t * 0.9 + 1.7) * 0.005)

        let board = bus.snapshot()

        var u = RenderUniforms()
        u.resolution = SIMD2(Float(size.width), Float(size.height))
        u.time = t
        u.spin = Float(model.spinSign)
        u.center = lean + wob
        u.rotation = t * 0.5
        u.diskIncline = 0.62
        u.guide = SIMD4(0, 0, model.captureReachUnits, model.guideAlpha)
        u.filTime = SIMD4(board.0.t0, board.1.t0, board.2.t0, 0)
        u.filR0   = SIMD4(board.0.r0, board.1.r0, board.2.r0, 0)
        u.filA0   = SIMD4(board.0.a0, board.1.a0, board.2.a0, 0)
        u.filC0   = SIMD4(board.0.r, board.0.g, board.0.b, 1)
        u.filC1   = SIMD4(board.1.r, board.1.g, board.1.b, 1)
        u.filC2   = SIMD4(board.2.r, board.2.g, board.2.b, 1)

        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<RenderUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()

        #if os(macOS)
        if debugSnapshots,
           let snapTime = scheduleSnap(t: Double(t), board: board),
           snapTime,
           let blit = cb.makeBlitCommandEncoder() {
            let tex = drawable.texture
            let bpr = tex.width * 4
            if let buf = device.makeBuffer(length: bpr * tex.height, options: .storageModeShared) {
                blit.copy(from: tex, sourceSlice: 0, sourceLevel: 0,
                          sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                          sourceSize: MTLSize(width: tex.width, height: tex.height, depth: 1),
                          to: buf, destinationOffset: 0,
                          destinationBytesPerRow: bpr,
                          destinationBytesPerImage: bpr * tex.height)
                blit.endEncoding()
                let w = tex.width, h = tex.height
                let idx = shotIndex; shotIndex += 1
                cb.addCompletedHandler { [buf] _ in
                    self.writeSnapshot(buf, width: w, height: h, index: idx)
                }
            } else {
                blit.endEncoding()
            }
        }
        #endif

        cb.present(drawable)
        cb.commit()
    }

    #if os(macOS)
    private func scheduleSnap(t: Double, board: (FilamentSlot, FilamentSlot, FilamentSlot)) -> Bool? {
        let newest = max(board.0.t0, max(board.1.t0, board.2.t0))
        if newest <= -900 { return nil }
        if Int(newest * 1000) != lastEmitCount {
            lastEmitCount = Int(newest * 1000)
            pendingShots = [newest + 0.35, newest + 1.1, newest + 1.9, newest + 2.6]
                .map { Double($0) }
        }
        if let first = pendingShots.first, t >= first {
            pendingShots.removeFirst()
            return true
        }
        return false
    }

    private func writeSnapshot(_ buf: MTLBuffer, width: Int, height: Int, index: Int) {
        let src = buf.contents().assumingMemoryBound(to: UInt8.self)
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            rgba[i*4+0] = src[i*4+2]   // B -> R
            rgba[i*4+1] = src[i*4+1]
            rgba[i*4+2] = src[i*4+0]   // R -> B
            rgba[i*4+3] = src[i*4+3]
        }
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bitmapFormat: [], bytesPerRow: width * 4,
                                         bitsPerPixel: 32) else { return }
        rgba.withUnsafeBufferPointer { ptr in
            guard let dst = rep.bitmapData else { return }
            memcpy(dst, ptr.baseAddress, rgba.count)
        }
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BlackHoleShots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("bh_shot_\(index).png")
        try? png.write(to: path)
    }
    #endif
}

extension BlackHoleModel {
    var lastPointerUV: SIMD2<Float> {
        SIMD2(Float(min(max(lastPointer.x / max(viewSize.width, 1), 0), 1)),
              Float(min(max(lastPointer.y / max(viewSize.height, 1), 0), 1)))
    }
}

// MARK: - MetalView (双平台)

#if os(macOS)
struct MetalStage: NSViewRepresentable {
    let model: BlackHoleModel
    func makeCoordinator() -> RendererHolder { RendererHolder(model: model) }
    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 60
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.framebufferOnly = false
        view.delegate = context.coordinator.renderer
        return view
    }
    func updateNSView(_ nsView: MTKView, context: Context) {
        let bounds = nsView.bounds
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { return }
        let scale = nsView.window?.backingScaleFactor ?? 2
        let ds = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        if ds != nsView.drawableSize { nsView.drawableSize = ds }
    }
}
#else
struct MetalStage: UIViewRepresentable {
    let model: BlackHoleModel
    func makeCoordinator() -> RendererHolder { RendererHolder(model: model) }
    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 60
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.delegate = context.coordinator.renderer
        return view
    }
    func updateUIView(_ uiView: MTKView, context: Context) {
        let s = uiView.bounds.size
        uiView.drawableSize = CGSize(width: s.width * uiView.contentScaleFactor,
                                     height: s.height * uiView.contentScaleFactor)
    }
}
#endif

final class RendererHolder {
    let renderer: BlackHoleRenderer?
    init(model: BlackHoleModel) {
        renderer = BlackHoleRenderer(model: model)
    }
}

// MARK: - 文件夹图标

struct FolderGlyph: View {
    let color: Color
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let tabW = w * 0.45
            let tabH = h * 0.16
            let bodyY = tabH * 0.55
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(color.opacity(0.5))
                    .frame(width: tabW, height: tabH)
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(LinearGradient(colors: [color, color.opacity(0.5)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: w, height: h - bodyY)
                    .overlay(
                        VStack {
                            Spacer()
                            Rectangle().fill(.white.opacity(0.12)).frame(height: 3)
                        }
                    )
            }
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(color.opacity(0.85), lineWidth: 1.3)
                    .frame(width: w, height: h - bodyY)
                    .offset(y: bodyY)
            )
        }
    }
}

// MARK: - 卡片视图

struct FloatingCardView: View {
    let card: FileCard
    let index: Int
    @ObservedObject var model: BlackHoleModel
    let size: CGSize

    var body: some View {
        if model.isFalling(card.id) {
            dissolvingBody
        } else {
            visual
                .gesture(dragGesture)
        }
    }

    private var visual: some View {
        if let drag = model.activeDrag, drag.id == card.id {
            let hole = model.holeCenter
            let dx = hole.x - drag.pos.x, dy = hole.y - drag.pos.y
            let radial = drag.withinReach ? atan2(dy, dx) : 0
            let stretch = 1 + drag.strain * 0.9
            return bodyVisual(pos: drag.pos,
                              rot: radial,
                              scaleX: stretch,
                              scaleY: 1 - drag.strain * 0.35,
                              opacity: 1,
                              saturation: 1 + drag.strain * 0.4,
                              brightness: drag.nearHorizon ? 0.25 : 0.1,
                              blur: 0)
        } else {
            return bodyVisual(pos: model.dockPosition(index: index, size: size),
                              rot: 0, scaleX: 1, scaleY: 1, opacity: 1,
                              saturation: 1, brightness: 0, blur: 0)
        }
    }

    static let shardCount = 28

    /// S0 (0 → 0.60s): 潮汐撕拉 —— 连续形变, 无切片缝隙。
    /// 整张文件是同一条流线上的材质: 近黑洞的角先被引力拽住,
    /// 弯折波从头传到尾, 拉伸率 (潮汐差应力) 头部最大向尾衰减,
    /// 拉得越狠越白热, 最后整条拉长的光带溶入 GPU 光丝。
    private var dissolvingBody: some View {
        let sw = model.swallows[card.id]
        return TimelineView(.animation) { tl in
            if let sw {
                let t = min(1, max(0, CGFloat(tl.date.timeIntervalSince(sw.start)) / model.dissolveDuration))
                if t >= 1 {
                    DispatchQueue.main.async { model.completeSwallow(card.id) }
                }
                let joints = self.shredJoints(self.shredCtx(sw), t: t)
                return AnyView(ZStack {
                    ForEach(0..<Self.shardCount, id: \.self) { i in
                        self.shardView(sw, t: t, i: i, joints: joints)
                    }
                }
                // 静态卡的投影由整个切片组共享一个代替 (单次离屏, 28 片各带一个太贵),
                // 撕拉开始后 0.25s 内随形变淡出
                .shadow(color: card.color.opacity(0.35 * max(0, 1 - 4 * t)), radius: 14, x: 0, y: 6))
            } else {
                return AnyView(Color.clear)
            }
        }
    }

    private struct ShredCtx {
        let hole: CGPoint
        let spin: CGFloat
        let sliceW: CGFloat
        let cardW: CGFloat
        let startX: CGFloat, startY: CGFloat   // 静止卡中心 (落点, 无拖拽)
        let axX: CGFloat                       // 卡轴朝黑洞侧的水平方向 ±1
        let rB: CGFloat                        // 出生点半径 (屏幕高度单位 = 抓取点)
        let aB: CGFloat                        // 出生点方位角
        let cosI: CGFloat                      // 盘倾角 (与 u.diskIncline 一致)
        let H: CGFloat                         // 画布高 (点)
        let flipped: Bool
    }

    private func shredCtx(_ sw: SwallowState) -> ShredCtx {
        let hole = model.holeCenter
        let h = max(model.viewSize.height, 1)
        let startX = hole.x + cos(sw.ang0) * sw.r0
        let startY = hole.y - sin(sw.ang0) * sw.r0
        return ShredCtx(hole: hole, spin: model.spinSign,
                        sliceW: model.cardW / CGFloat(Self.shardCount), cardW: model.cardW,
                        startX: startX, startY: startY,
                        axX: hole.x > startX ? 1 : -1,
                        rB: sw.hr0 / h, aB: sw.ha0,
                        cosI: 0.62, H: h,
                        flipped: hole.x > startX)
    }

    /// 撕裂关节点 J[0..n]: 材质边 f=0 (头) → f=1 (尾)。
    /// 头精确钉在 GPU 光丝流线的头部 (renderStream 中心股 k=1, uH = u − 0.05),
    /// 未流入流线的材质沿出生径向向外延伸 —— 角与吸积盘起点全程相连。
    private func shredJoints(_ ctx: ShredCtx, t: CGFloat) -> [CGPoint] {
        let n = Self.shardCount
        let W = ctx.cardW
        let RISCO: CGFloat = 0.265
        let OM: CGFloat = 19.0

        // 流线上的点 (屏幕点): s ∈ [0, uH], 与 shader 公式逐项一致
        // 钉在领先股 k=0 (uH=u, aK=a0−spreadA) —— 否则最亮的领先丝会从
        // 卡尖前面以不同角度窜出, 形成假折角
        let uT = min(0.2, t * 0.2)               // 0.6s 撕裂窗口 / DUR 3s
        let uH = uT
        let r0c = max(ctx.rB, RISCO * 1.02)
        let spreadA = 0.020 + 0.080 * smStep(0.0, 0.40, uT)
        func streamPt(_ s: CGFloat) -> CGPoint {
            let rd = (r0c + (RISCO - r0c) * pow(s, 1.55)) * ctx.H
            let aa = (ctx.aB - spreadA) + ctx.spin * OM * pow(s, 1.45)
            return CGPoint(x: ctx.hole.x + cos(aa) * rd,
                           y: ctx.hole.y - sin(aa) * rd * ctx.cosI)
        }
        // 弧长表: 沿流线从出生点累计 (头在 s=uH, 距头的弧长 = L − cum(s))
        let K = 48
        var cum: [CGFloat] = [0]
        for j in 1...K {
            let p1 = streamPt(CGFloat(j - 1) / CGFloat(K) * uH)
            let p2 = streamPt(CGFloat(j) / CGFloat(K) * uH)
            cum.append(cum[j - 1] + hypot(p2.x - p1.x, p2.y - p1.y))
        }
        let L = cum[K]

        // 延伸段: 出生点的时间反演螺旋 (流线同族曲线的镜像) —— 交点 C1 连续,
        // 曲率过渡自然成 S 形, 不会有直线段岔开的角度
        func extPt(_ sE: CGFloat) -> CGPoint {
            let rd = (r0c + (r0c - RISCO) * pow(sE, 1.55)) * ctx.H
            let aa = (ctx.aB - spreadA) - ctx.spin * OM * pow(sE, 1.45)
            return CGPoint(x: ctx.hole.x + cos(aa) * rd,
                           y: ctx.hole.y - sin(aa) * rd * ctx.cosI)
        }
        let sEmax: CGFloat = 0.22
        let KE = 32
        var cumE: [CGFloat] = [0]
        for j in 1...KE {
            let q1 = extPt(CGFloat(j - 1) / CGFloat(KE) * sEmax)
            let q2 = extPt(CGFloat(j) / CGFloat(KE) * sEmax)
            cumE.append(cumE[j - 1] + hypot(q2.x - q1.x, q2.y - q1.y))
        }

        // 拉伸率 (潮汐差应力, 头大尾小) → 材质点距头的弧长
        let stretch = 1.8 * pow(t, 1.6)
        let whip    = 1.2 * pow(t, 1.8)
        func arcAt(_ f: CGFloat) -> CGFloat {
            W * (f + (stretch / 3) * CGFloat(1 - exp(-3 * Double(f)))
                   + (whip / 2) * CGFloat(1 - exp(-6 * Double(f))))
        }
        // 弧长 → 流线参数 (超出部分沿外向延伸)
        func locate(_ A: CGFloat) -> CGPoint {
            let B = L - A                        // 距出生点的弧长
            if B >= 0 {
                let Bcl = min(B, L)
                var j = 0
                while j < K && cum[j + 1] < Bcl { j += 1 }
                let seg = max(cum[j + 1] - cum[j], 1e-6)
                let fr = (Bcl - cum[j]) / seg
                return streamPt((CGFloat(j) + fr) / CGFloat(K) * uH)
            }
            let d = -B
            if d >= cumE[KE] { return extPt(sEmax) }
            var jE = 0
            while jE < KE && cumE[jE + 1] < d { jE += 1 }
            let segE = max(cumE[jE + 1] - cumE[jE], 1e-6)
            let frE = (d - cumE[jE]) / segE
            return extPt((CGFloat(jE) + frE) / CGFloat(KE) * sEmax)
        }

        var J: [CGPoint] = []
        J.reserveCapacity(n + 1)
        for jf in 0...n {
            let f = CGFloat(jf) / CGFloat(n)
            let restX = ctx.startX + ctx.axX * (W / 2 - f * W)
            let restY = ctx.startY
            let bw = smStep(0.05, 0.55, t - 0.30 * f)      // 弯折波: 头先尾后
            let sp = locate(arcAt(f))
            J.append(CGPoint(x: restX + (sp.x - restX) * bw,
                             y: restY + (sp.y - restY) * bw))
        }
        return J
    }

    /// 单个撕裂切片: 可见片段两端精确落在相邻关节点上 (弦长 = 片宽), 数学上无缝
    private func shardView(_ sw: SwallowState, t: CGFloat, i: Int, joints J: [CGPoint]) -> some View {
        let ctx = shredCtx(sw)
        let n = Self.shardCount
        // 贴图左/右边缘对应的关节 (贴图左缘 = 卡片左缘; 头在近黑洞侧)
        let kL: Int, kR: Int
        if ctx.axX > 0 { kL = n - i; kR = n - 1 - i }   // 头在贴图右缘: 贴图左缘 = 尾侧
        else          { kL = i;     kR = i + 1 }        // 头在贴图左缘
        let pL = J[kL], pR = J[kR]
        let dx = pR.x - pL.x, dy = pR.y - pL.y
        let chord = max(hypot(dx, dy), 0.5)
        let sx = chord / ctx.sliceW               // 不 clamp: clamp 会破坏无缝铺瓦
        let rot = atan2(dy, dx)
        let mid = CGPoint(x: (pL.x + pR.x) / 2, y: (pL.y + pR.y) / 2)

        // 条带偏移补偿: 蒙版片段偏离元素中心 (i+0.5)*sliceW - W/2,
        // 旋转/缩放绕元素中心会把这个偏移也转过去 —— 反向平移抵消,
        // 可见片段才能精确落在 [pL, pR] 上 (v4 的教训, 丢了就是梳齿缝)
        let ex = (CGFloat(i) + 0.5) * ctx.sliceW - ctx.cardW / 2
        let cx = mid.x - cos(rot) * sx * ex
        let cy = mid.y - sin(rot) * sx * ex

        // 亮度/透明度按材质坐标 (0 = 头) 计算
        let fMid = ctx.axX > 0 ? 1 - (CGFloat(i) + 0.5) / CGFloat(n)
                               : (CGFloat(i) + 0.5) / CGFloat(n)
        let bw = smStep(0.05, 0.55, t - 0.30 * fMid)
        let stretch = 1.8 * pow(t, 1.6)
        let whip    = 1.2 * pow(t, 1.8)
        let sq  = 1 + stretch * CGFloat(exp(-3 * Double(fMid)))
                + 3 * whip * CGFloat(exp(-6 * Double(fMid)))
        let lit = max(smStep(1.08, 1.9, sq), 0.85 * smStep(0.70, 1.0, t))
        // 局部转角越大条带越细: 消除旋转梳齿, 且"拉成细光带"叙事一致
        let angK: (Int) -> CGFloat = { k in
            let a = min(k, n - 1)
            let q1 = J[ctx.axX > 0 ? n - a : a]
            let q2 = J[ctx.axX > 0 ? n - 1 - a : a + 1]
            return atan2(q2.y - q1.y, q2.x - q1.x)
        }
        var dth = abs(angK(i + 1) - angK(i))
        if dth > .pi { dth = 2 * .pi - dth }
        let sy  = (1 - 0.60 * bw) * max(0.30, 1 - 5.0 * dth)
        let op  = 1 - 0.93 * smStep(0.82 + 0.08 * fMid, 1.0, t)

        // 轻量脸 (lite): 静态填充 + 无投影, 防 28 片离屏合成跳帧;
        // 圆角前 0.12s 从 14 → 2 连续过渡, 与静态卡交接零跳变
        return cardFace(cornerRadius: max(2, 14 - 100 * max(0, t)), lite: true)
            .frame(width: model.cardW, height: model.cardH)
            .mask(Rectangle()
                .frame(width: ctx.sliceW + 2.4, height: model.cardH)
                .offset(x: -model.cardW / 2 + ctx.sliceW * (CGFloat(i) + 0.5)))
            .blur(radius: lit > 0.002 ? 0.4 + 5.0 * lit : 0)      // 未化光不模糊 (少一次离屏), 化光处晕开
            .brightness(0.05 + 1.3 * lit)                         // 化光处过曝白热
            .saturation(1 + 0.6 * t)
            .scaleEffect(x: sx, y: sy, anchor: .center)
            .rotationEffect(.radians(rot))
            .position(CGPoint(x: cx, y: cy))
            .opacity(op)
    }

    /// 卡片正脸: 整卡渲染与撕裂切片共用
    @ViewBuilder
    private func cardFace(cornerRadius: CGFloat = 14, lite: Bool = false) -> some View {
        let rounded = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let content = VStack(spacing: 6) {
            ZStack {
                FolderGlyph(color: card.color)
                Image(systemName: card.glyph)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                    .offset(y: -2)
            }
            .frame(width: 64, height: 48)
            Text(card.name)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(1)
        }
        .padding(.top, 10)
        .padding(.horizontal, 6)
        .padding(.bottom, 6)

        if lite {
            // 撕裂切片专用轻量脸: 28 片若各带 ultraThinMaterial (实时背景模糊)
            // + radius14 投影, 每帧 56 次离屏合成全压在撕拉首帧 —— 跳帧元凶。
            // 黑底上静态填充观感与材质一致, 投影由整个切片组共享一个代替
            content
                .background(Color.white.opacity(0.13), in: rounded)
                .overlay(rounded.strokeBorder(card.color.opacity(0.5), lineWidth: 1))
        } else {
            content
                .background(.ultraThinMaterial, in: rounded)
                .overlay(rounded.strokeBorder(card.color.opacity(0.5), lineWidth: 1))
                .shadow(color: card.color.opacity(0.35), radius: 14, x: 0, y: 6)
        }
    }

    private func bodyVisual(pos: CGPoint, rot: CGFloat, scaleX: CGFloat, scaleY: CGFloat,
                            opacity: Double, saturation: Double, brightness: Double,
                            blur: CGFloat) -> some View {
        Group {
            cardFace()
                .saturation(saturation)
                .brightness(brightness)
                .blur(radius: blur)
        }
        .frame(width: model.cardW, height: model.cardH)
        .rotationEffect(.radians(rot))
        .scaleEffect(x: scaleX, y: scaleY, anchor: .center)
        .opacity(opacity)
        .position(pos)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(SceneSpace))
            .onChanged { v in
                model.lastPointer = CGPoint(x: v.location.x / size.width, y: v.location.y / size.height)
                model.dragChanged(card, location: v.location)
            }
            .onEnded { _ in
                model.dragEnded(card)
            }
    }
}

// MARK: - HUD

struct HUDView: View {
    @ObservedObject var model: BlackHoleModel

    var instruction: String {
        if let drag = model.activeDrag, drag.nearHorizon {
            return "RELEASE — gravity is taking it"
        }
        if !model.swallows.isEmpty {
            return "MASS → LIGHT conversion in progress"
        }
        return "DRAG A FILE CARD TOWARD THE EVENT HORIZON"
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Label("EVENT HORIZON", systemImage: "circle.grid.cross.fill")
                            .font(.system(size: 13, weight: .heavy, design: .rounded))
                            .tracking(2)
                        Text("GRAVITY RECYCLE BIN")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)

                Spacer()

                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(instruction)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .tracking(1)
                        HStack(spacing: 4) {
                            Text("FILES CONSUMED")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text("\(model.eatenCount)")
                                .font(.system(size: 18, weight: .heavy, design: .rounded))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
            }
            .allowsHitTesting(false)

            VStack {
                HStack {
                    Spacer()
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { model.reset() }
                    } label: {
                        Label("RESET", systemImage: "arrow.counterclockwise")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(.white.opacity(0.12), in: Capsule())
                            .overlay(Capsule().strokeBorder(.white.opacity(0.25)))
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 18)
                    .padding(.top, 12)
                }
                Spacer()
            }
        }
        .foregroundStyle(.white)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: model.eatenCount)
    }
}

// MARK: - 主场景

private let SceneSpace = "holeScene"

struct FileDropDelegate: DropDelegate {
    let model: BlackHoleModel

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.fileURL])
    }

    func dropEntered(info: DropInfo) {
        withAnimation(.easeOut(duration: 0.2)) { model.hasInteracted = true }
    }

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [UTType.fileURL])
        guard let provider = providers.first else { return false }

        let location = info.location
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            var url: URL? = item as? URL
            if url == nil, let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
            if let url {
                DispatchQueue.main.async {
                    model.swallowExternalFile(at: location, url: url)
                }
            }
        }
        return true
    }
}

struct BlackHoleScene: View {
    @StateObject var model = BlackHoleModel()

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                MetalStage(model: model)
                    .ignoresSafeArea()

                ForEach(Array(model.deckOrder.enumerated()), id: \.element) { indexed in
                    if let card = model.cardData[indexed.element] {
                        let visIndex = model.visibleOrder.firstIndex(of: indexed.element) ?? model.visibleOrder.count
                        FloatingCardView(card: card,
                                         index: model.isFalling(indexed.element) ? 0 : visIndex,
                                         model: model,
                                         size: size)
                            .zIndex(model.activeDrag?.id == indexed.element ? 10 : 1)
                    }
                }

                HUDView(model: model)

                introOverlay(size: size)
                    .opacity(model.hasInteracted ? 0 : 1)
                    .animation(.easeOut(duration: 1.2), value: model.hasInteracted)
            }
            .background(Color.black.ignoresSafeArea())
            .contentShape(Rectangle())
            .coordinateSpace(name: SceneSpace)
            #if os(macOS)
            .onContinuousHover { phase in
                if case .active(let pt) = phase {
                    model.lastPointer = CGPoint(x: pt.x / size.width, y: pt.y / size.height)
                }
            }
            #endif
            .onDrop(of: [UTType.fileURL], delegate: FileDropDelegate(model: model))
            .onAppear { model.viewSize = size }
            .onChange(of: size) { newSize in model.viewSize = newSize }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }

    private func introOverlay(size: CGSize) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 22))
                .foregroundColor(.white)
            Text("drag a file card into the void")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
            Text("watch it spaghettify into pure light")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(22)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .position(x: size.width * 0.5, y: size.height * 0.22)
        .allowsHitTesting(false)
    }
}

// MARK: - 启动

@main
struct BlackHoleApp: App {
    var body: some Scene {
        WindowGroup {
            BlackHoleScene()
                .frame(minWidth: 640, minHeight: 480)
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        #endif
    }
}
