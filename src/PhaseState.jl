using Parameters
using SpecialFunctions
using LinearAlgebra
using Tracker
using ReverseDiff
using RecursiveArrayTools

@inline function calcgibbs(ph::U,T::W) where {U<:IdealPhase,W<:Real}
    return getGibbs.(getfield.(ph.species,:thermo),T)
end
export calcgibbs

@inline function calcenthalpyinternalgibbs(ph::U,T::W,P::Z,V::Q) where {U<:IdealPhase,W,Z,Q<:Real}
    Hs = getEnthalpy.(getfield.(ph.species,:thermo),T)
    Us = Hs .- P*V
    Gs = Hs .- T.*getEntropy.(getfield.(ph.species,:thermo),T)
    return Hs,Us,Gs
end


@inline function calcenthalpyinternalgibbs(ph::Union{IdealGas,IdealSurface},T::W,P::Z,V::Q) where {W,Z,Q<:Real}
    Hs = getEnthalpy.(getfield.(ph.species,:thermo),T)
    Us = Hs .- R*T
    Gs = Hs .- T.*getEntropy.(getfield.(ph.species,:thermo),T)
    return Hs,Us,Gs
end

export calcenthalpyinternalgibbs

function makespcsvector(phase,spcdict)
    y0 = zeros(length(phase.species))
    spnames = [x.name for x in phase.species]
    for (key,val) in spcdict
        if key == "T"
            continue
        elseif key == "P"
            continue
        elseif key == "V"
            continue
        elseif key == "Hin"
            continue
        else
            ind = findfirst(isequal(key),spnames)
            @assert typeof(ind)<: Integer  "$key not found in species list: $spnames"
            y0[ind] = val
        end
    end
    return y0
end

export makespcsvector

@inline function getkf(rxn::ElementaryReaction,ph,T,P,C,ns,V,phi)
    if isdefined(rxn.kinetics,:efficiencies) && length(rxn.kinetics.efficiencies) > 0
        @views @inbounds @fastmath C += sum([ns[i]*val for (i,val) in rxn.kinetics.efficiencies])/V
    end
    return rxn.kinetics(T=T,P=P,C=C,phi=phi)
end
export getkf

@inline function getkfs(ph::U,T::W1,P::W2,C::W3,ns::Q,V::W4,phi) where {U,W1,W2,W3,W4<:Real,Q<:AbstractArray}
    kfs = similar(ns,length(ph.reactions))
    i = 1
    oldind = 1
    ind = 0
    while i <= length(ph.veckineticsinds) #vectorized kinetics
        @inbounds ind = ph.veckineticsinds[i]
        @inbounds kfs[oldind:ind] = ph.veckinetics[i](;T=T,P=P,C=C)
        oldind = ind+1
        i += 1
    end
    @simd for i in ind+1:length(ph.reactions)
        @inbounds kfs[i] = getkf(ph.reactions[i],ph,T,P,C,ns,V,phi)
    end
    return kfs
end

export getkfs

"""
Calculates the diffusion limited rate coefficient
for 1 spc returns Inf
for 2 spc calculates using the Smolchowski equation
for >2 spc calculates using the Generalized Smolchowski equation
Equations from Flegg 2016
"""
@inline function getDiffusiveRate(spcs::Q,diffs::Array{W,1}) where {Q<:AbstractArray,W<:Real}
    if length(spcs) == 1
        return Inf
    elseif length(spcs) == 2
        @fastmath @inbounds kf = 4.0*Base.pi*(diffs[spcs[1].index]+diffs[spcs[2].index])*(spcs[1].radius+spcs[2].radius)*Na
    else
        @views @inbounds diffusivity = diffs[getfield.(spcs,:index)]
        N = length(spcs)
        @fastmath a = (3.0*length(spcs)-5.0)/2.0
        @fastmath Dinv = 1.0./diffusivity
        @fastmath Dbar = 1.0./reverse(cumsum(Dinv))
        @fastmath Dhat = diffusivity .+ Dbar
        @fastmath @inbounds deltaN = sum(Dinv)/sum([sum([1.0/(diffusivity[i]*diffusivity[m]) for m in 1:N-1 if i>m]) for i in 2:N])
        @views @fastmath @inbounds kf = prod(Dhat[2:end].^1.5)*4*Base.pi^(a+1)/gamma(a)*(sum(getfield.(spcs,:radius))/sqrt(deltaN))^(2*a)*Na^(N-1)
    end
    return kf
end
export getDiffusiveRate

@inline function getKc(rxn::ElementaryReaction,ph::U,T::Z,Gs::Q,phi::V=0.0) where {U<:AbstractPhase,V,Q,Z<:Real}
    Nreact = length(rxn.reactantinds)
    Nprod = length(rxn.productinds)
    dGrxn = 0.0
    if Nreact == 1
        @fastmath @inbounds dGrxn -= Gs[rxn.reactantinds[1]]
    elseif Nreact == 2
        @fastmath @inbounds dGrxn -= Gs[rxn.reactantinds[1]]+Gs[rxn.reactantinds[2]]
    elseif Nreact == 3
        @fastmath @inbounds dGrxn -= Gs[rxn.reactantinds[1]]+Gs[rxn.reactantinds[2]]+Gs[rxn.reactantinds[3]]
    elseif Nreact == 4
        @fastmath @inbounds dGrxn -= Gs[rxn.reactantinds[1]]+Gs[rxn.reactantinds[2]]+Gs[rxn.reactantinds[3]]+Gs[rxn.reactantinds[4]]
    end
    if Nprod == 1
        @fastmath @inbounds dGrxn += Gs[rxn.productinds[1]]
    elseif Nprod == 2
        @fastmath @inbounds dGrxn += Gs[rxn.productinds[1]]+Gs[rxn.productinds[2]]
    elseif Nprod == 3
        @fastmath @inbounds dGrxn += Gs[rxn.productinds[1]]+Gs[rxn.productinds[2]]+Gs[rxn.productinds[3]]
    elseif Nprod == 4
        @fastmath @inbounds dGrxn += Gs[rxn.productinds[1]]+Gs[rxn.productinds[2]]+Gs[rxn.productinds[3]]+Gs[rxn.productinds[4]]
    end
    return @inbounds @fastmath exp(-(dGrxn+rxn.electronchange*phi)/(R*T))*(getC0(ph,T))^(Nprod-Nreact)
end

@inline function getKc(rxn::ElementaryReaction,phase1,phase2,Gs1,Gs2,T,phi=0.0) #for constant k interfaces
    dGrxn = 0.0
    dN1 = 0
    dN2 = 0
    for r in rxn.reactants
        isfirst = true
        ind = findfirst(isequal(r),phase1.species)
        if ind === nothing
            isfirst = false
            ind = findfirst(isequal(r),phase2.species)
            dGrxn -= Gs2[ind]
            dN2 -= 1
        else 
            dGrxn -= Gs1[ind]
            dN1 -= 1
        end
    end
    for r in rxn.products
        isfirst = true
        ind = findfirst(isequal(r),phase1.species)
        if ind === nothing
            isfirst = false
            ind = findfirst(isequal(r),phase2.species)
            dGrxn += Gs2[ind]
            dN2 += 1
        else 
            dGrxn += Gs1[ind]
            dN1 += 1
        end
    end
    return @inbounds @fastmath exp(-(dGrxn+rxn.electronchange*phi)/(R*T))*getC0(phase1,T)^dN1*getC0(phase2,T)^dN2
end
export getKc

@inline function getKcs(ph::U,T::Z,Gs::Q) where {U<:AbstractPhase,Q,Z<:Real}
    return @fastmath @inbounds exp.(ph.stoichmatrix*(Gs./(R*T)) .+ ph.Nrp.*log(getC0(ph,T)));
end

@inline function getKcs(ph::U,T::Z,Gs::Q,phi::V) where {U<:AbstractPhase,Q,Z<:Real,V<:Real}
    return @fastmath @inbounds exp.(ph.stoichmatrix*(Gs./(R*T)).+ph.electronchange.*(phi/(R*T)) .+ ph.Nrp.*log(getC0(ph,T)));
end

@inline function getKcs(ph,T,Gs1,Gs2)
    Gpart = ArrayPartition(Gs1,Gs2)
    return @fastmath @inbounds exp.(ph.stoichmatrix*(Gpart./(R*T)) .+ ph.Nrp1.*log(getC0(ph.domain1.phase,T)) .+ ph.Nrp2.*log(getC0(ph.domain2.phase,T)));
end

export getKcs

"""
Calculates the forward and reverse rate coefficients for a given reaction, phase and state
Maintains diffusion limitations if the phase has diffusionlimited=true
"""
@inline function getkfkrev(rxn::ElementaryReaction,ph::U,T::W1,P::W2,C::W3,N::W4,ns::Q1,Gs::Q2,diffs::Q3,V::W5,phi::W8;kf::W6=-1.0,f::W7=-1.0) where {U<:AbstractPhase,W8,W6,W7,W5,W4,W1,W2,W3<:Real,Q1,Q2,Q3<:AbstractArray}
    if signbit(kf) 
        if signbit(f)
            kf = getkf(rxn,ph,T,P,C,ns,V,phi)
        else
            kf = getkf(rxn,ph,T,P,C,ns,V,phi)*f
        end
    end
    Kc = getKc(rxn,ph,T,Gs,phi)
    @fastmath krev = kf/Kc
    if ph.diffusionlimited
        if length(rxn.reactants) == 1
            if length(rxn.products) > 1
                krevdiff = getDiffusiveRate(rxn.products,diffs)
                @fastmath krev = krev*krevdiff/(krev+krevdiff)
                @fastmath kf = Kc*krev
            end
        elseif length(rxn.products) == 1
            kfdiff = getDiffusiveRate(rxn.reactants,diffs)
            @fastmath kf = kf*kfdiff/(kf+kfdiff)
            @fastmath krev = kf/Kc
        elseif length(rxn.products) == length(rxn.reactants)
            kfdiff = getDiffusiveRate(rxn.reactants,diffs)
            krevdiff = getDiffusiveRate(rxn.products,diffs)
            @fastmath kff = kf*kfdiff/(kf+kfdiff)
            @fastmath krevr = krev*krevdiff/(krev+krevdiff)
            @fastmath kfr = Kc*krevr
            if kff > kfr
                kf = kfr
                krev = krevr
            else
                kf = kff
                @fastmath krev = kf/Kc
            end
        end
    end
    kf *= rxn.forwardable
    krev *= rxn.reversible
    return (kf,krev)
end
export getkfkrev

@inline function getkfkrevs(phase::U,T::W1,P::W2,C::W3,N::W4,ns::Q1,Gs::Q2,diffs::Q3,V::W5,phi::W7;kfs::W6=nothing) where {U,W7,W6,W5<:Real,W1<:Real,W2<:Real,W3,W4,Q1<:AbstractArray,Q2,Q3<:AbstractArray}
    if !phase.diffusionlimited && kfs === nothing
        kfs = getkfs(phase,T,P,C,ns,V,phi)
        if phi == 0.0
            krev = @fastmath kfs./getKcs(phase,T,Gs)
        else 
            krev = @fastmath kfs./getKcs(phase,T,Gs,phi)
        end
    elseif !phase.diffusionlimited && !(kfs === nothing)
        if phi == 0.0
            krev = @fastmath kfs./getKcs(phase,T,Gs)
        else 
            krev = @fastmath kfs./getKcs(phase,T,Gs,phi)
        end
    elseif phase.diffusionlimited && !(kfs === nothing)
        len = length(phase.reactions)
        krev = zeros(typeof(N),len)
        @simd for i = 1:len
           @fastmath @inbounds kfs[i],krev[i] = getkfkrev(phase.reactions[i],phase,T,P,C,N,ns,Gs,diffs,V,phi;kf=kfs[i])
        end
    else
        len = length(phase.reactions)
        kfs = zeros(typeof(N),len)
        krev = zeros(typeof(N),len)
        @simd for i = 1:len
           @fastmath @inbounds kfs[i],krev[i] = getkfkrev(phase.reactions[i],phase,T,P,C,N,ns,Gs,diffs,V,phi)
        end
    end
    kfs .*= phase.forwardability
    krev .*= phase.reversibility
    return kfs,krev
end

@inline function getkfkrevs(phase::U,T::W1,P::W2,C::W3,N::W4,ns::Q1,Gs::Q2,diffs::Q3,V::W5,phi::W7;kfs::W6=nothing) where {U,W7,W6,W5<:Real,W1<:Real,W2<:Real,W3,W4,Q1<:AbstractArray,Q2<:Union{ReverseDiff.TrackedArray,Tracker.TrackedArray},Q3<:AbstractArray} #autodiff p
    if !phase.diffusionlimited && kfs === nothing
        kfs = getkfs(phase,T,P,C,ns,V,phi)
        if phi == 0.0
            krev = @fastmath kfs./getKcs(phase,T,Gs)
        else 
            krev = @fastmath kfs./getKcs(phase,T,Gs,phi)
        end
    elseif !phase.diffusionlimited && !(kfs === nothing)
        if phi == 0.0
            krev = @fastmath kfs./getKcs(phase,T,Gs)
        else 
            krev = @fastmath kfs./getKcs(phase,T,Gs,phi)
        end
    elseif phase.diffusionlimited && !(kfs === nothing)
        len = length(phase.reactions)
        krev = similar(kfs)
        kfsdiff = similar(kfs)
        @simd for i = 1:len
           @fastmath @inbounds kfsdiff[i],krev[i] = getkfkrev(phase.reactions[i],phase,T,P,C,N,ns,Gs,diffs,V,phi;kf=kfs[i])
        end
        return kfsdiff, krev
    else
        len = length(phase.reactions)
        kfs = zeros(typeof(Gs[1]),len)
        krev = zeros(typeof(Gs[1]),len)
        @simd for i = 1:len
           @fastmath @inbounds kfs[i],krev[i] = getkfkrev(phase.reactions[i],phase,T,P,C,N,ns,Gs,diffs,V,phi)
        end
    end
    return kfs,krev
end

@inline function getkfkrevs(phase::U,T::W1,P::W2,C::W3,N::W4,ns::Q1,Gs::Array{Q2,1},diffs::Q3,V::W5,phi::W7;kfs::W6=nothing) where {U,W7,W6,W5<:Real,W1<:Real,W2<:Real,W3,W4,Q1<:AbstractArray,Q2<:ForwardDiff.Dual,Q3<:AbstractArray} #autodiff p
    if !phase.diffusionlimited && kfs === nothing
        kfs = getkfs(phase,T,P,C,ns,V,phi)
        if phi == 0.0
            krev = @fastmath kfs./getKcs(phase,T,Gs)
        else 
            krev = @fastmath kfs./getKcs(phase,T,Gs,phi)
        end
    elseif !phase.diffusionlimited && !(kfs === nothing)
        if phi == 0.0
            krev = @fastmath kfs./getKcs(phase,T,Gs)
        else 
            krev = @fastmath kfs./getKcs(phase,T,Gs,phi)
        end
    elseif phase.diffusionlimited && !(kfs === nothing)
        len = length(phase.reactions)
        krev = similar(kfs)
        @simd for i = 1:len
           @fastmath @inbounds kfs[i],krev[i] = getkfkrev(phase.reactions[i],phase,T,P,C,N,ns,Gs,diffs,V,phi;kf=kfs[i])
        end
    else
        len = length(phase.reactions)
        kfs = zeros(typeof(Gs[1]),len)
        krev = zeros(typeof(Gs[1]),len)
        @simd for i = 1:len
           @fastmath @inbounds kfs[i],krev[i] = getkfkrev(phase.reactions[i],phase,T,P,C,N,ns,Gs,diffs,V,phi)
        end
    end
    kfs .*= phase.forwardability
    krev .*= phase.reversibility
    return kfs,krev
end

export getkfkrevs
