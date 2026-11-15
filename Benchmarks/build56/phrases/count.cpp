// Count local context in public clean text. Never store/release the original sentences.
#include <cstdio>
#include <fstream>
#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>
#include <deque>
#include <algorithm>
using U=uint64_t; using Counts=std::unordered_map<U,uint32_t>; constexpr U prime=1099511628211ull, start=14695981039346656037ull;
U word(const std::string&s){U h=start; for(unsigned char c:s)h=(h^c)*prime;return h;}
U mix(U a,U b){return (a^b)*prime;}
U key(int kind,U a,U b=0,U c=0){U h=mix(start,kind);h=mix(h,a);if(b)h=mix(h,b);if(c)h=mix(h,c);return h;}
int main(int argc,char**argv){
 if(argc<3)return 1;
 Counts uni,bi,tri;std::string line,s;std::ifstream f(argv[1]);size_t lines=0;
 while(std::getline(f,line)){U a=0,b=0;auto flush=[&](){if(s.empty())return;U h=word(s);++uni[key(1,h)];if(b)++bi[key(2,b,h)];if(a&&b)++tri[key(3,a,b,h)];a=b;b=h;s.clear();};
 for(unsigned char c:line){if(c>='A'&&c<='Z')c+='a'-'A';if((c>='a'&&c<='z')||(c=='\''&&!s.empty()))s+=c;else{flush();if(c!=' '&&c!='\t'){a=b=0;}}}flush();++lines;}
 std::vector<std::pair<U,uint32_t>> out;
 for(auto &kv:uni)if(kv.second>=5)out.push_back(kv);
 for(auto &kv:bi)if(kv.second>=5)out.push_back(kv);
 for(auto &kv:tri)if(kv.second>=5)out.push_back(kv);
 std::sort(out.begin(),out.end());
 std::ofstream g(argv[2],std::ios::binary); for(auto &kv:out){g.write((char*)&kv.first,8);uint32_t x=kv.second;g.write((char*)&x,4);}
 fprintf(stderr,"%zu source lines; %zu entries retained\n",lines,out.size());
}
