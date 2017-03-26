# Note: Functions surrounded by a comment blocks are there because `Vararg` is sitll allocating.
# When Vararg is fast enough, they can simply be removed

####################
# PseudoBlockArray #
####################

"""
    PseudoBlockArray{T, N, R} <: AbstractBlockArray{T, N}

A `PseudoBlockArray` is similar to a [`BlockArray`](@ref) except the full array is stored
contiguously instead of block by block. This means that is not possible to insert and retrieve
blocks without copying data. On the other hand `Array` on a `PseudoBlockArray` is instead instant since
it just returns the wrapped array.

When iteratively solving a set of equations with a gradient method the Jacobian typically has a block structure. It can be convenient
to use a `PseudoBlockArray` to build up the Jacobian block by block and then pass the resulting matrix to
a direct solver using `Array`.

```jldoctest
julia> srand(12345);

julia> A = PseudoBlockArray(rand(2,3), [1,1], [2,1])
2×2-blocked 2×3 BlockArrays.PseudoBlockArray{Float64,2,Array{Float64,2}}:
 0.562714  0.371605  │  0.381128
 --------------------┼----------
 0.849939  0.283365  │  0.365801

julia> A = PseudoBlockArray(sprand(6, 0.5), [3,2,1])
3-blocked 6-element BlockArrays.PseudoBlockArray{Float64,1,SparseVector{Float64,Int64}}:
 0.0
 0.586598
 0.0
 ---------
 0.0501668
 0.0
 ---------
 0.0
```
"""
struct PseudoBlockArray{T, N, R <: AbstractArray{T, N}} <: AbstractBlockArray{T, N}
    blocks::R
    block_sizes::BlockSizes{N}
end

const PseudoBlockMatrix{T, R} = PseudoBlockArray{T, 2, R}
const PseudoBlockVector{T, R} = PseudoBlockArray{T, 1, R}
const PseudoBlockVecOrMat{T, R} = Union{PseudoBlockMatrix{T, R}, PseudoBlockVector{T, R}}

# Auxiliary outer constructors
@inline function PseudoBlockArray{T, N, R <: AbstractArray{T, N}}(blocks::R, block_sizes::BlockSizes{N})
    return PseudoBlockArray{T, N, R}(blocks, block_sizes)
end

@inline function PseudoBlockArray{T, N, R <: AbstractArray{T, N}}(blocks::R, block_sizes::Vararg{Vector{Int}, N})
    return PseudoBlockArray{T, N, R}(blocks, BlockSizes(block_sizes...))
end


###########################
# AbstractArray Interface #
###########################

function Base.similar{T,N,T2}(block_array::PseudoBlockArray{T,N}, ::Type{T2})
    PseudoBlockArray(similar(block_array.blocks, T2), copy(block_array.block_sizes))
end

@generated function Base.size{T,N}(arr::PseudoBlockArray{T,N})
    exp = Expr(:tuple, [:(arr.block_sizes[$i][end] - 1) for i in 1:N]...)
    return quote
        @inbounds return $exp
    end
end

@inline function Base.getindex{T, N}(block_arr::PseudoBlockArray{T, N}, i::Vararg{Int, N})
    @boundscheck checkbounds(block_arr, i...)
    @inbounds v = block_arr.blocks[i...]
    return v
end


@inline function Base.setindex!{T, N}(block_arr::PseudoBlockArray{T, N}, v, i::Vararg{Int, N})
    @boundscheck checkbounds(block_arr, i...)
    @inbounds block_arr.blocks[i...] = v
    return block_arr
end

################################
# AbstractBlockArray Interface #
################################


@inline nblocks(block_array::PseudoBlockArray) = nblocks(block_array.block_sizes)
@inline blocksize{T, N}(block_array::PseudoBlockArray{T,N}, i::Vararg{Int, N}) = blocksize(block_array.block_sizes, i)


############
# Indexing #
############


@inline function getblock{T,N}(block_arr::PseudoBlockArray{T,N}, block::Vararg{Int, N})
    range = globalrange(block_arr.block_sizes, block)
    return block_arr.blocks[range...]
end

function _check_getblock!{T, N}(blockrange, x, block_arr::PseudoBlockArray{T,N}, block::NTuple{N, Int})
    for i in 1:N
        if size(x, i) != length(blockrange[i])
            throw(DimensionMismatch(string("tried to assign ", blocksize(block_arr, block...), " block to $(size(x)) array")))
        end
    end
end


@generated function getblock!{T,N}(x, block_arr::PseudoBlockArray{T,N}, block::Vararg{Int, N})
    return quote
        blockrange = globalrange(block_arr.block_sizes, block)
        @boundscheck _check_getblock!(blockrange, x, block_arr, block)

        arr = block_arr.blocks
        @nexprs $N d -> k_d = 1
        @inbounds begin
            @nloops $N i (d->(blockrange[d])) (d-> k_{d-1}=1) (d-> k_d+=1) begin
                (@nref $N x k) = (@nref $N arr i)
            end
        end
        return x
    end
end

function _check_setblock!{T, N}(blockrange, x, block_arr::PseudoBlockArray{T,N}, block::NTuple{N, Int})
    blocksizes = blocksize(block_arr, block...)
    for i in 1:N
        if size(x, i) != blocksizes[i]
            throw(DimensionMismatch(string("tried to assign $(size(x)) array to ", blocksizes, " block")))
        end
    end
end


@generated function setblock!{T, N}(block_arr::PseudoBlockArray{T, N}, x, block::Vararg{Int, N})
    return quote
        blockrange = globalrange(block_arr.block_sizes, block)
        @boundscheck _check_setblock!(blockrange, x, block_arr, block)
        arr = block_arr.blocks
        @nexprs $N d -> k_d = 1
        @inbounds begin
            @nloops $N i (d->(blockrange[d])) (d-> k_{d-1}=1) (d-> k_d+=1) begin
                (@nref $N arr i) = (@nref $N x k)
            end
        end
    end
end

########
# Misc #
########

function Base.Array(block_array::PseudoBlockArray)
    return block_array.blocks
end

function Base.copy!{T, N, R <: AbstractArray}(block_array::PseudoBlockArray{T, N, R}, arr::R)
    copy!(block_array.blocks, arr)
end

function Base.fill!(block_array::PseudoBlockArray, v)
    fill!(block_array.blocks, v)
end