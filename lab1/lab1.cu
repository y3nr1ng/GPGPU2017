#include "lab1.h"

// Library
#include <cuda_runtime.h>
#include <math_constants.h>

// Internal
#include "cutil_math.h"

// System
#include <iostream>
#include <sstream>      // stringstream
#include <fstream>      // ofstream

#define EPS     1e-4f

#define gpuErrChk(func) { gpuAssert((func), __FILE__, __LINE__); }
inline void gpuAssert(
    cudaError_t ret,
    const char *fname,
    int line,
    bool forceStop=true
) {
    if (ret != cudaSuccess) {
        std::cerr << "CUDA Error: " << cudaGetErrorString(ret);
        std::cerr << ' ' << fname;
        std::cerr << " ln" << line << std::endl;
        if (forceStop) {
            exit(ret);
        }
    }
}

#define DIVUP(a, b) ((a+b-1)/b)

struct Ray {
    float3 orig;    // origin
    float3 dir;     // direction

    __device__
    Ray() {
    }

    __host__ __device__
    Ray(const float3 _orig, const float3 _dir)
        : orig(_orig), dir(_dir) {
    }
};

/*
 * Reflection type
 */
enum Refl_t {
    DIFF = 1,   // diffuse
    SPEC,       // speckle
    REFR        // refract
};

struct Sphere {
     float rad;            // radius
     float3 pos, emi, col; // position, emission, colour
     Refl_t refl;          // reflection type (e.g. diffuse)

    __device__
    float distance(const Ray &ray) const {
        /*
         * ray equation: p(x, y, z) = ray.orig + t*ray.dir
         * sphere equation: x^2 + y^2 + z^2 = rad^2
         *
         * quadratic: ax^2 + bx + c = 0 -> x = (-b +- sqrt(b^2 - 3ac)) / 2a
         *
         * solve t^2*ray.dir*ray.dir + 2*t*(orig-p)*ray.dir + (orig-p)*(orig-p) - rad*rad = 0
         */
         float3 dist = pos - ray.orig;
         float b = dot(dist, ray.dir);

         // discriminant
         float disc = b*b - dot(dist, dist) + rad*rad;

        if (disc < 0) {
            // ignroe complex solution
            return 0;
        } else {
            disc = sqrtf(disc);
        }
        // return the closest point relative the the origin of light ray
        float t;
        return ((t = b - disc) > EPS) ? t : ( ((t = b + disc) > EPS) ? t : 0 );
     }
};

__constant__
Ray c_camera;
__constant__
Sphere  c_spheres[8];

__device__
inline bool intersect_scene(const Ray &r, float &t, int &id) {
    float n = sizeof(c_spheres) / sizeof(Sphere), d;
    t = CUDART_INF_F;  // t is distance to closest intersection, initialise t to a huge number outside scene
    for (int i = int(n); i--;) { // test all scene objects for intersection
        if ((d = c_spheres[i].distance(r)) && (d < t)) {  // if newly computed intersection distance d is smaller than current closest intersection distance
            t = d;  // keep track of distance along ray to closest intersection point
            id = i; // and closest intersected object
        }
    }
    return (t < CUDART_INF_F); // returns true if an intersection with the scene occurred, false when no hit
}

// random number generator from https://github.com/gz/rust-raytracer

__device__
static float getrandom(unsigned int *seed0, unsigned int *seed1) {
    *seed0 = 36969 * ((*seed0) & 65535) + ((*seed0) >> 16);  // hash the seeds using bitwise AND and bitshifts
    *seed1 = 18000 * ((*seed1) & 65535) + ((*seed1) >> 16);

    unsigned int ires = ((*seed0) << 16) + (*seed1);

    // Convert to float
    union {
        float f;
        unsigned int ui;
    } res;

    res.ui = (ires & 0x007fffff) | 0x40000000;  // bitwise AND, bitwise OR

    return (res.f - 2.f) / 2.f;
}

/*
 * rendering equation:
 * outgoing radiance at a point = emitted radiance + reflected radiance
 *
 * reflected radiance = sum of (incoming radiance from hemisphere above point)
 *                      * reflectance function of material
 *                      * cosine incident angle
 */
__device__
float3 radiance(Ray ray, unsigned int *s1, unsigned int *s2){
    float3 color = make_float3(0.0f); // accumulated color
    float3 mask = make_float3(1.0f);

    // bounce the ray
    for (int count = 0; count < 4; count++) {
        float t;           // distance to closest intersection
        int id = 0;        // index of closest intersected sphere

        // test whether the scence is intersected
        if (!intersect_scene(ray, t, id)) {
            // return black if missed
            return make_float3(0.0f);
        }

        // compute impact location and normal vector
        const Sphere &obj =  c_spheres[id];
        float3 p = ray.orig + ray.dir * t;  // impact location
        float3 n = normalize(p - obj.pos);  // normal
        // convert to front facing
        n = (dot(n, ray.dir) < 0) ? n : n * (-1);

        // add the photons from current object to accumulate the color
        color += mask * obj.emi;

        /*
         * generate new diffuse ray
         *     .orig = impac location
         *     .dir = random direction above the impact location
         */
        float r1 = 2 * CUDART_PI_F * getrandom(s1, s2); // pick random number on unit circle (radius = 1, circumference = 2*Pi) for azimuth
        float r2 = getrandom(s1, s2);  // pick random number for elevation
        float r2s = sqrtf(r2);

        // compute local orthonormal basis uvw at hitpoint to use for calculation random ray direction
        // first vector = normal at hitpoint, second vector is orthogonal to first, third vector is orthogonal to first two vectors
        float3 w = n;
        float3 u = normalize(cross((fabs(w.x) > .1 ? make_float3(0, 1, 0) : make_float3(1, 0, 0)), w));
        float3 v = cross(w, u);

        // compute random ray direction on hemisphere using polar coordinates
        // cosine weighted importance sampling (favours ray directions closer to normal direction)
        float3 d = normalize(u*cos(r1)*r2s + v*sin(r1)*r2s + w*sqrtf(1 - r2));

        // new ray origin is intersection point of previous ray with scene
        ray.orig = p + n*0.05f; // offset ray origin slightly to prevent self intersection
        ray.dir = d;

        mask *= obj.col;    // multiply with colour of object
        mask *= dot(d, n);  // weigh light contribution using cosine of angle between incident light and normal
        mask *= 2;          // fudge factor
    }

    return color;
}

__global__
void renderKernel(
    float3 *frame,
    const int width,
    const int height,
    const int ntrials
) {
    const unsigned int x = blockIdx.x*blockDim.x + threadIdx.x;
    const unsigned int y = blockIdx.y*blockDim.y + threadIdx.y;

    if ((x >= width) || (y >= height)) {
        return;
    }

    // calculate the index, y direction flipped
    //unsigned int i = y*width + x;
    unsigned int i = (height - y - 1) * width + x;

    unsigned int s1 = x;  // seeds for random number generator
    unsigned int s2 = y;

    // generate ray directed at lower left corner of the screen
    // compute directions for all other rays by adding cx and cy increments in x and y direction
    float3 cx = make_float3(width * .5135 / height, 0.0f, 0.0f); // ray direction offset in x direction
    float3 cy = normalize(cross(cx, c_camera.dir)) * .5135; // ray direction offset in y direction (.5135 is field of view angle)
    float3 r; // r is final pixel color

    r = make_float3(0.0f);

    // sampling for each pixel
    for (int s = 0; s < ntrials; s++) {
        // compute primary ray direction
        float3 d = c_camera.dir + cx*((.25 + x) / width - .5) + cy*((.25 + y) / height - .5);

        // create primary ray, add incoming radiance to pixelcolor
        r = r + radiance(Ray(c_camera.orig + d * 40, normalize(d)), &s1, &s2)*(1. / ntrials);
                   // Camera rays are pushed ^^^^^^ forward to start in interior
    }

    // write rgb value of pixel to image buffer on the GPU, clamp value to [0.0f, 1.0f] range
    frame[i] = clamp(r, 0.0f, 1.0f);
}

__device__
uint8_t flt2int(float x) {
	return uint8_t(pow(clamp(x, 0.0f, 1.0f), 1/2.2f) * 255 + .5);
}

__global__
void convertKernel(
    uint8_t *out,
    const float3 *in,
    const int width,
    const int height
) {
	const unsigned int ix = blockIdx.x*blockDim.x + threadIdx.x;
	const unsigned int iy = blockIdx.y*blockDim.y + threadIdx.y;

	if ((ix >= width) || (iy >= height)) {
		return;
	}

	unsigned int i = (height - iy - 1) * width + ix;

	uint8_t r = flt2int(in[i].x);
	uint8_t g = flt2int(in[i].y);
	uint8_t b = flt2int(in[i].z);

	// calculate y plane
	float y = 0.299f * r + 0.587f * g + 0.114f * b;
	out[i] = y;

	// subsample u/v plane
	if ((ix%2 == 0) && (iy%2 == 0)) {
		float3 c0 = in[i];
		float3 c1 = in[(height - iy - 1) * width + (ix+1)];
		float3 c2 = in[(height - (iy+1) - 1) * width + ix];
		float3 c3 = in[(height - (iy+1) - 1) * width + (ix+1)];

		c0 += c1;
		c0 += c2;
		c0 += c3;

		c0 /= 4;

		r = flt2int(c0.x);
		g = flt2int(c0.y);
		b = flt2int(c0.z);

		float u = -0.169f * r - 0.331f * g + 0.500f * b + 128;
		float v = 0.500f * r - 0.419f * g - 0.081f * b + 128;

		const unsigned int offset = width * height;
		out[offset + iy/2 * width/2 + ix/2] = u;
		out[offset + (offset/4) + iy/2 * width/2 + ix/2] = v;
	}
}

/*
 * using 9 spheres to form a cornell box
 *
 * {
 *     float radius,
 *     { float3 position },
 *     { float3 emission },
 *     { float3 color },
 *     Refl_t refl
 * }
 */
Sphere h_spheres[] = {
    { 1e5f, { 1e5f + 1.0f, 40.8f, 81.6f }, { 0.0f, 0.0f, 0.0f }, { 0.75f, 0.25f, 0.25f }, DIFF }, //Left
    { 1e5f, { -1e5f + 99.0f, 40.8f, 81.6f }, { 0.0f, 0.0f, 0.0f }, { .25f, .25f, .75f }, DIFF }, //Right
    { 1e5f, { 50.0f, 40.8f, 1e5f }, { 0.0f, 0.0f, 0.0f }, { .75f, .75f, .75f }, DIFF }, //Back
    { 1e5f, { 50.0f, 40.8f, -1e5f + 600.0f }, { 0.0f, 0.0f, 0.0f }, { 1.00f, 1.00f, 1.00f }, DIFF }, //Frnt
    { 1e5f, { 50.0f, 1e5f, 81.6f }, { 0.0f, 0.0f, 0.0f }, { .75f, .75f, .75f }, DIFF }, //Botm
    { 1e5f, { 50.0f, -1e5f + 81.6f, 81.6f }, { 0.0f, 0.0f, 0.0f }, { .75f, .75f, .75f }, DIFF }, //Top
    { 8.0f, { 50.0f, 40.0f, 78.0f }, { 0.0f, 0.0f, 0.0f }, { 1.0f, 1.0f, 1.0f }, DIFF }, // small sphere 2
    { 600.0f, { 50.0f, 681.6f - .50f, 81.6f }, { 2.0f, 1.8f, 1.6f }, { 0.0f, 0.0f, 0.0f }, DIFF }  // Light
};

void updatePhysics(const int fid, const int priId=6) {
    float theta = 2*CUDART_PI_F * fid/60;
    h_spheres[priId].pos = make_float3(
        16.0f * cosf(theta) + 50.0f,
        16.0f * sinf(theta) + 40.0f,
        78.0f
    );
}

struct Lab1VideoGenerator::Impl {
	const int width = 640, height = 480;
	int nelem;
	size_t nbytes;

	const int ntrials = 3072;

	const int nframe = 120;
	int iframe = 0;

	// frame in rgb
	float3 *h_frame;
	float3 *d_frame;

	Impl() {
		nelem = width * height;
		nbytes = nelem * sizeof(float3);
	}
};

Lab1VideoGenerator::Lab1VideoGenerator()
	: impl(new Impl) {
	// generate frame storage
	impl->h_frame = new float3[impl->nelem];
	gpuErrChk(cudaMalloc(&impl->d_frame, impl->nbytes));

	// copy camera position to constant memory
	Ray camera(
		make_float3(50, 52, 295.6),
		normalize(make_float3(0, -0.042612, -1))
	);
	gpuErrChk(cudaMemcpyToSymbol(c_camera, &camera, sizeof(Ray)));
}

Lab1VideoGenerator::~Lab1VideoGenerator() {
	gpuErrChk(cudaFree(impl->d_frame));
    delete[] impl->h_frame;
}

void Lab1VideoGenerator::Generate(uint8_t *yuv) {
	dim3 threads(16, 16);
    dim3 blocks(
		DIVUP(impl->width, threads.x),
		DIVUP(impl->height, threads.y)
	);

	// update the position
	updatePhysics(impl->iframe);
	gpuErrChk(cudaMemcpyToSymbol(c_spheres, &h_spheres, sizeof(h_spheres)));

	// render the view
	renderKernel<<<blocks, threads>>>(impl->d_frame, impl->width, impl->height, impl->ntrials);

	// convert from rgb to yuv444
	convertKernel<<<blocks, threads>>>(yuv, impl->d_frame, impl->width, impl->height);

	// increase frame number
	std::cout << impl->iframe << std::endl << std::flush;
	++(impl->iframe);
}

void Lab1VideoGenerator::get_info(Lab1VideoInfo &info) {
	info.w = impl->width;
	info.h = impl->height;
	info.n_frame = impl->nframe;

	// fps = 24/1 = 24
	info.fps_n = 24;
	info.fps_d = 1;
};
