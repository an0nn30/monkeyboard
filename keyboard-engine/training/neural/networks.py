import torch
from torch import nn
from torch.nn import functional as F
D, V, T = 64, 8192, 32

class CausalLM(nn.Module):
    def __init__(self):
        super().__init__()
        self.e = nn.Embedding(V,D); self.k=nn.Linear(D,D,bias=False)
        self.v=nn.Linear(D,D,bias=False); self.q=nn.Linear(D,D,bias=False)
        self.h=nn.Linear(2*D,D); self.out=nn.Linear(D,V)
    def forward(self,x):
        e=self.e(x)
        a=F.scaled_dot_product_attention(self.q(e)[:,None],self.k(e)[:,None],self.v(e)[:,None],is_causal=True)[:,0]
        return self.out(torch.tanh(self.h(torch.cat([e,a],dim=-1))))
class Block(nn.Module):
    def __init__(self, d):
        super().__init__()
        self.norm=nn.LayerNorm(d); self.norm2=nn.LayerNorm(d)
        self.qkv=nn.Linear(d,3*d); self.o=nn.Linear(d,d)
        self.ff=nn.Sequential(nn.Linear(d,4*d),nn.GELU(),nn.Linear(4*d,d))
    def forward(self,x):
        b,t,d=x.shape
        q,k,v=self.qkv(self.norm(x)).view(b,t,3,6,d//6).permute(2,0,3,1,4).unbind(0)
        y=F.scaled_dot_product_attention(q,k,v,is_causal=True).transpose(1,2).reshape(b,t,d)
        x=x+self.o(y)
        return x+self.ff(self.norm2(x))
class Decoder(nn.Module):
    def __init__(self):
        super().__init__()
        d=384
        self.emb=nn.Embedding(V,d); self.pos=nn.Embedding(T+1,d)
        self.layers=nn.Sequential(*(Block(d) for _ in range(5)))
        self.norm=nn.LayerNorm(d); self.out=nn.Linear(d,V)
    def forward(self,x):
        h=self.emb(x)+self.pos(torch.arange(x.shape[1],device=x.device))[None]
        return self.out(self.norm(self.layers(h)))
