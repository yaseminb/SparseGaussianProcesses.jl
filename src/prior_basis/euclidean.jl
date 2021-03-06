import Random.rand!
using TensorCast

export EuclideanRandomFeatures

"""
    EuclideanRandomFeatures

A set of Euclidean random features, parameterized by frequency and phase,
together with a set of associated basis weights.
"""
mutable struct EuclideanRandomFeatures{A<:AbstractArray{<:Any,3},M<:AbstractMatrix} <: PriorBasis
  frequency  :: A
  phase      :: M
  weights    :: M
end

Flux.trainable(f::EuclideanRandomFeatures) = ()
Flux.@functor EuclideanRandomFeatures

"""
    rand!(self::EuclideanRandomFeatures, k::EuclideanKernel, 
          num_features::Int = size(self.frequency,ndims(self.frequency)))

Draw a new set of random features, by randomly sampling a new frequencies
from the spectral measure, and new phases uniformly from ``(0, 2\\pi)``.
Does NOT automatically resample the GP containing the features.
"""
function rand!(self::EuclideanRandomFeatures, k::EuclideanKernel; num_features::Int = size(self.frequency,ndims(self.frequency)))
  (id,od) = k.dims
  (_,s) = size(self.weights)
  Fl = eltype(self.frequency)
  self.frequency = spectral_distribution(k; num_samples = num_features)
  self.phase = Fl(2*pi) .* rand!(similar(self.phase, (od,num_features)))
  self.weights = randn!(similar(self.weights, (num_features, s)))
  nothing
end

"""
    EuclideanRandomFeatures(k::EuclideanKernel, num_features::Int)

Create a set of Euclidean random features with eigenvalues given by the 
spectral distribution given by ``k``.
"""
function EuclideanRandomFeatures(k::EuclideanKernel, num_features::Int)
  (id,od) = k.dims
  frequency = zeros(id,od,num_features)
  phase = zeros(od,num_features)
  weights = zeros(num_features,1)
  features = EuclideanRandomFeatures(frequency, phase, weights)
  rand!(features, k)
  features
end

"""
    (self::EuclideanRandomFeatures)(x::AbstractMatrix, w::AbstractMatrix, 
                                    k::EuclideanKernel)

Evaluate the ``f(x)`` where ``f`` is a Gaussian process with kernel ``k``, 
and ``x`` is the data, using the random features.
"""
function (self::EuclideanRandomFeatures)(x::AbstractMatrix, k::EuclideanKernel)
  Fl = eltype(self.frequency)
  l = size(self.frequency, ndims(self.frequency))
  (outer_weights, inner_weights) = spectral_weights(k, self.frequency)
  @cast rescaled_x[ID,N] := x[ID,N] / inner_weights[ID]
  @matmul basis_fn_inner_prod[OD,L,N] := sum(ID) self.frequency[ID,OD,L] * rescaled_x[ID,N]
  @cast basis_fn[OD,L,N] := cos(basis_fn_inner_prod[OD,L,N] + self.phase[OD,L])
  basis_weight = outer_weights .* sqrt(Fl(2)) ./ sqrt(Fl(l)) .* self.weights
  @matmul output[OD,N,S] := sum(L) basis_fn[OD,L,N] * basis_weight[L,S]
  output
end

"""
    (self::EuclideanRandomFeatures)(x::AbstractMatrix, w::AbstractMatrix, 
                                    k::GradientKernel{<:EuclideanKernel})

Evaluate ``(\\nabla g)(x)`` where ``g`` is a Gaussian process with kernel ``k``,
``\\nabla`` is the gradient inter-domain operator, and ``x`` is the data, using
the random features.
"""
function (self::EuclideanRandomFeatures)(x::AbstractMatrix, k::GradientKernel{<:EuclideanKernel})
  Fl = eltype(self.frequency)
  l = size(self.frequency, ndims(self.frequency))
  (outer_weights, inner_weights) = spectral_weights(k, self.frequency)
  @cast rescaled_x[ID,N] := x[ID,N] / inner_weights[ID]
  @matmul basis_fn_inner_prod[OD,L,N] := sum(ID) self.frequency[ID,OD,L] * rescaled_x[ID,N]
  @cast basis_fn_grad_outer[OD,L,N] := -sin(basis_fn_inner_prod[OD,L,N] + self.phase[OD,L])
  @cast basis_fn_grad[ID,OD,L,N] := basis_fn_grad_outer[OD,L,N] * self.frequency[ID,OD,L] / inner_weights[ID]
  basis_weight = outer_weights .* sqrt(Fl(2)) ./ sqrt(Fl(l)) .* self.weights
  @matmul output[ID,OD,N,S] := sum(L) basis_fn_grad[ID,OD,L,N] * basis_weight[L,S]
  dropdims(output; dims=2)
end

"""
    (self::EuclideanRandomFeatures)(x::AbstractArray{<:Any,3},w::AbstractMatrix, 
                                    k::GradientKernel{<:EuclideanKernel})

Evaluate ``(\\nabla g)(x)`` where ``g`` is a Gaussian process with kernel ``k``,
``\\nabla`` is the gradient inter-domain operator, and ``x`` is the batched 
data, using the random features.
"""
function (self::EuclideanRandomFeatures)(a::AbstractArray{<:Any,3}, k::GradientKernel{<:EuclideanKernel})
  (d,n,s) = size(a)
  x = reshape(a, (:,n*s))
  Fl = eltype(self.frequency)
  l = size(self.frequency, ndims(self.frequency))
  (outer_weights, inner_weights) = spectral_weights(k, self.frequency)
  @cast rescaled_x[ID,N] := x[ID,N] / inner_weights[ID]
  @matmul basis_fn_inner_prod[OD,L,N] := sum(ID) self.frequency[ID,OD,L] * rescaled_x[ID,N]
  @cast basis_fn_grad_outer[OD,L,N] := -sin(basis_fn_inner_prod[OD,L,N] + self.phase[OD,L])
  @cast basis_fn_grad[ID,OD,L,N] := basis_fn_grad_outer[OD,L,N] * self.frequency[ID,OD,L] / inner_weights[ID]
  basis_weight = outer_weights .* sqrt(Fl(2)) ./ sqrt(Fl(l)) .* self.weights
  basis_fn_grad_batched = reshape(basis_fn_grad, (d,l,n,s))
  @reduce output[ID,N,S] := sum(L) basis_fn_grad_batched[ID,L,N,S] * basis_weight[L,S]
  output
end