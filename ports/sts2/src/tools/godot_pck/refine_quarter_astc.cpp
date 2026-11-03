// INPUT: tightly packed RGBA, audited dimensions and fixed astcenc parameters
// OUTPUT: block-compressed bytes and decoded RGBA for offline quality validation
// POS: isolated build-time helper linked to pinned ARM astcenc 5.3.0; never shipped
#include <astcenc.h>
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <vector>

int main(int argc, char **argv) {
 if (argc != 10) return 2;
 int w=std::atoi(argv[2]),h=std::atoi(argv[3]),block=std::atoi(argv[4]);
 float quality=std::atof(argv[5]), alpha=std::atof(argv[6]); bool alphaw=std::atoi(argv[7]);
 if(w<=0||h<=0||(block!=4&&block!=8))return 3;
 std::ifstream f(argv[1],std::ios::binary);std::vector<uint8_t> src(w*h*4);f.read((char*)src.data(),src.size());if(!f||f.peek()!=EOF)return 4;
 int pw=((w+block-1)/block)*block,ph=((h+block-1)/block)*block;
 std::vector<uint8_t> input(pw*ph*4),decoded(pw*ph*4),compressed((pw/block)*(ph/block)*16);
 for(int y=0;y<ph;y++)for(int x=0;x<pw;x++)for(int c=0;c<4;c++)input[(y*pw+x)*4+c]=src[(std::min(y,h-1)*w+std::min(x,w-1))*4+c];
 astcenc_config config{};unsigned flags=alphaw?ASTCENC_FLG_USE_ALPHA_WEIGHT:0;
 auto err=astcenc_config_init(ASTCENC_PRF_LDR,block,block,1,quality,flags,&config);if(err)return 5;
 config.cw_a_weight=alpha;if(alphaw)config.a_scale_radius=1;
 astcenc_context *ctx=nullptr;err=astcenc_context_alloc(&config,1,&ctx);if(err)return 6;
 void* plane=input.data();astcenc_image img{(unsigned)pw,(unsigned)ph,1,ASTCENC_TYPE_U8,&plane};
 astcenc_swizzle sw{ASTCENC_SWZ_R,ASTCENC_SWZ_G,ASTCENC_SWZ_B,ASTCENC_SWZ_A};
 err=astcenc_compress_image(ctx,&img,&sw,compressed.data(),compressed.size(),0);if(err)return 7;
 void* dst=decoded.data();astcenc_image out{(unsigned)pw,(unsigned)ph,1,ASTCENC_TYPE_U8,&dst};
 err=astcenc_decompress_image(ctx,compressed.data(),compressed.size(),&out,&sw,0);if(err)return 8;
 astcenc_context_free(ctx);
 std::ofstream c(argv[8],std::ios::binary);c.write((char*)compressed.data(),compressed.size());
 std::ofstream d(argv[9],std::ios::binary);d.write((char*)decoded.data(),decoded.size());
 std::printf("%d %d %zu\n",pw,ph,compressed.size());return c&&d?0:9;
}
