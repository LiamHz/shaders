#iChannel0 "self"

#define PI 3.14159
#define N_BOUNCES 8
#define MIN_RAY_DIST 0.001
#define MAX_RAY_DIST 10000.0
#define NUM_RENDERS_PER_FRAME 4
#define EXPOSURE 0.5
#define ENABLE_AA true
#define ENABLE_RUSSIAN_ROULETTE true

// Function to generate random numbers in a shader
uint wang_hash(inout uint seed) {
    seed = uint(seed ^ uint(61)) ^ uint(seed >> uint(16));
    seed *= uint(9);
    seed = seed ^ (seed >> 4);
    seed *= uint(0x27d4eb2d);
    seed = seed ^ (seed >> 15);
    return seed;
}

float RandomFloat01(inout uint state) {
    return float(wang_hash(state)) / 4294967296.0;
}

vec3 RandomUnitVector(inout uint state) {
    float z = RandomFloat01(state) * 2.0f - 1.0f;
    float a = RandomFloat01(state) * 2.0 * PI;
    float r = sqrt(1.0f - z * z);
    float x = r * cos(a);
    float y = r * sin(a);
    return vec3(x, y, z);
}

// SRGB
vec3 LessThan(vec3 f, float value) {
    return vec3(
        (f.x < value) ? 1.0f : 0.0f,
        (f.y < value) ? 1.0f : 0.0f,
        (f.z < value) ? 1.0f : 0.0f);
}

vec3 LinearToSRGB(vec3 rgb) {
    rgb = clamp(rgb, 0.0f, 1.0f);

    return mix(
        pow(rgb, vec3(1.0f / 2.4f)) * 1.055f - 0.055f,
        rgb * 12.92f,
        LessThan(rgb, 0.0031308f)
    );
}

vec3 SRGBToLinear(vec3 rgb) {
    rgb = clamp(rgb, 0.0f, 1.0f);

    return mix(
        pow(((rgb + 0.055f) / 1.055f), vec3(2.4f)),
        rgb / 12.92f,
        LessThan(rgb, 0.04045f)
    );
}

// ACES tone mapping curve fit to go from HDR to LDR
//https://knarkowicz.wordpress.com/2016/01/06/aces-filmic-tone-mapping-curve/
vec3 ACESFilm(vec3 x) {
    float a = 2.51f;
    float b = 0.03f;
    float c = 2.43f;
    float d = 0.59f;
    float e = 0.14f;
    return clamp((x*(a*x + b)) / (x*(c*x + d) + e), 0.0f, 1.0f);
}

struct MaterialInfo {
    vec3 diffuse;
    vec3 emissive;
    vec3 specular;
    float percentSpec;
    float roughness;
};

struct Sphere {
    vec3 pos;
    float radius;
    MaterialInfo mat;
};

struct HitInfo {
    bool didHit;
    vec3 normal;
    vec3 hitPoint;
    MaterialInfo mat;
};

HitInfo sphereIntersect(vec3 rayOrigin, vec3 rayDir, Sphere sphere) {
    vec3 oc = rayOrigin - sphere.pos;
    float a = dot(rayDir, rayDir);
    float half_b = dot(oc, rayDir);
    float c = dot(oc, oc) - sphere.radius*sphere.radius;
    float discriminant = half_b*half_b - a*c;

    bool didHit = discriminant > 0.0 ? true : false;

    // Find the nearest root in the acceptable range
    float sqrtd = sqrt(discriminant);
    float root = (-half_b - sqrtd) / a;
    if (root < MIN_RAY_DIST || root > MAX_RAY_DIST) {
        root = (-half_b + sqrtd) / a;
        if (root < MIN_RAY_DIST || root > MAX_RAY_DIST) {
            didHit = false;
        }
    }

    vec3 hitPoint = rayOrigin + rayDir*root;
    // Normal is the vector going from the center of the sphere to the hit point
    vec3 normal = (hitPoint - sphere.pos) / sphere.radius;

    return HitInfo(didHit, normal, hitPoint, sphere.mat);
}

vec3 scene(vec3 rayOrigin, vec3 rayDir, inout uint rngState) {
    int nSpheres = 10;
    Sphere spheres[16];

    MaterialInfo metalYellow = MaterialInfo(vec3(0.9, 0.9, 0.5), vec3(0), vec3(0.9), 0.1, 0.2);
    MaterialInfo metalMagenta = metalYellow;
    MaterialInfo metalCyan  = metalYellow;
    metalMagenta.diffuse = vec3(0.9, 0.5, 0.9);
    metalMagenta.percentSpec = 0.3;
    metalMagenta.roughness = 0.2;
    metalCyan.diffuse  = vec3(0.5, 0.9, 0.9);

    MaterialInfo matteWhite = MaterialInfo(vec3(1.0), vec3(0), vec3(0), 0.0, 0.0);
    MaterialInfo matteRed   = matteWhite;
    MaterialInfo matteGreen = matteWhite;
    matteRed.diffuse   = vec3(1.0, 0.2, 0.2);
    matteGreen.diffuse = vec3(0.2, 1.0, 0.2);

    MaterialInfo lightSource = MaterialInfo(vec3(0), vec3(1.0, 0.9, 0.7), vec3(0), 0.0, 0.0);

    // Light Sources
    spheres[0] = Sphere(vec3(0, 18, 24), 10.0, lightSource);
    spheres[1] = Sphere(vec3(0, 16, 6), 10.0, lightSource);

    // Walls
    spheres[2] = Sphere(vec3(-108, 0, 30), 100.0, matteRed);
    spheres[3] = Sphere(vec3( 108, 0, 30), 100.0, matteGreen);
    spheres[4] = Sphere(vec3(0, 0,  136), 100.0, matteWhite);
    spheres[5] = Sphere(vec3(0, -103, 30), 100.0, matteWhite);
    spheres[6] = Sphere(vec3(0,  125.5, 30), 100.0, matteWhite);

    // Subjects
    spheres[7] = Sphere(vec3(-6, -1.6, 24), 2.0, metalYellow);
    spheres[8] = Sphere(vec3( 0, -1.6, 20), 2.0, metalMagenta);
    spheres[9] = Sphere(vec3( 6, -1.6, 24), 2.0, metalCyan);

    vec3 col = vec3(0);
    vec3 throughput = vec3(1);

    // Test for ray intersection against all spheres in scene
    // Set the ray color to the closest hit object in the scene
    // Note, without IBL, non-enclosed spaces will often appear
    // dark as rays will quickly bounce out of the scene
    for (int nBounce=0; nBounce <= N_BOUNCES; nBounce++) {
        float closestHit = MAX_RAY_DIST;
        HitInfo hitInfo;

        for (int i=0; i<nSpheres; i++) {
            HitInfo h = sphereIntersect(rayOrigin, rayDir, spheres[i]);
            float rayDist = length(rayOrigin-h.hitPoint);
            if (h.didHit && rayDist < closestHit && rayDist > MIN_RAY_DIST) {
                closestHit = rayDist;
                hitInfo = h;
            }
        }

        // No objects hit
        if (closestHit == MAX_RAY_DIST) {
            break;
        }

        // Bounce ray
        rayOrigin = hitInfo.hitPoint;

        // Decide if ray will be diffuse or specular
        bool isSpecRay = (RandomFloat01(rngState) < hitInfo.mat.percentSpec) ? true : false;
        vec3 diffuseRayDir = normalize(hitInfo.normal + RandomUnitVector(rngState));
        float specDirMix = hitInfo.mat.roughness * hitInfo.mat.roughness;
        vec3 specRayDir = normalize(mix(reflect(rayDir, hitInfo.normal), diffuseRayDir, specDirMix));
        rayDir = isSpecRay ? specRayDir: diffuseRayDir;

        // Add emissive lighting
        col += hitInfo.mat.emissive * throughput;

		// Propogate strength of light through bounces
        throughput *= isSpecRay ? hitInfo.mat.specular : hitInfo.mat.diffuse;

        // As the throughput gets smaller, the ray is more likely to get terminated early.
        // Survivors have their value boosted to make up for fewer samples being in the average.
        if (ENABLE_RUSSIAN_ROULETTE) {                
            float p = max(throughput.r, max(throughput.g, throughput.b));
        	if (RandomFloat01(rngState) > p)
            	break;

        	// Add the energy we 'lose' by randomly terminating paths
        	throughput *= 1.0f / p;   
        }
    }

    return col;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    // Set random seed based on frag coord and frame number
    uint rngState = uint(uint(fragCoord.x) * uint(1973) + uint(fragCoord.y) *\
                    uint(9277) + uint(iFrame) * uint(26699)) | uint(1);

    // Set 2D coordinates to range from -1 to 1
    // on the x-axis with the center as the origin
    vec2 fc = fragCoord;
    if (ENABLE_AA) {
        // Subpixel antialiasing
        vec2 jitter = vec2(RandomFloat01(rngState), RandomFloat01(rngState)) - 0.5;
        fc += jitter;
    }
    vec2 uv = (fc - 0.5*iResolution.xy)/iResolution.x;

    // Origin of the rays
    float fov = 90.0;
    float camDist = 1.0 / tan(fov * 0.5 * PI / 180.0);
    vec3 rayOrigin = vec3(0);

    // Get the direction of the ray from the origin to a pixel
    vec3 rayDir = normalize(vec3(uv.x, uv.y, camDist));
    vec3 sceneCol = vec3(0);
    for (int i=0; i<NUM_RENDERS_PER_FRAME; i++) {
        sceneCol += scene(rayOrigin, rayDir, rngState) / float(NUM_RENDERS_PER_FRAME);
    } 

    // Average the color of the frames together
    vec3 lastFrameCol = texture(iChannel0, fragCoord/iResolution.xy).rgb;
    vec3 col = mix(lastFrameCol, sceneCol, 1.0 / float(iFrame+1));

    // Process color
    col *= EXPOSURE;
    col = ACESFilm(sceneCol);
    col = LinearToSRGB(sceneCol);
    col = mix(lastFrameCol, col, 1.0 / float(iFrame+1));
    fragColor = vec4(col, 1.0);
}
