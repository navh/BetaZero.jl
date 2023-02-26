module LightDark

using Distributions
using Parameters
using ParticleFilters
using POMDPModels
using POMDPTools
using POMDPs
using Random

export
    LightDarkPOMDP,
    LightDarkState,
    LDNormalStateDist,
    ParticleHistoryBelief,
    ParticleHistoryBeliefUpdater

"""
    LightDarkState

## Fields
- `y`: position
- `status`: 0 = normal, negative = terminal
"""
struct LightDarkState
    status::Int64
    y::Float64
end


"""
    LightDarkPOMDP

A one-dimensional light dark problem. The goal is to be near 0. Observations are noisy measurements of the position.
"""
@with_kw mutable struct LightDarkPOMDP <: POMDPs.POMDP{LightDarkState,Int,Float64}
    discount_factor::Float64 = 0.9
    correct_r::Float64 = 100.0
    incorrect_r::Float64 = -100.0
    step_size::Float64 = 1.0
    movement_cost::Float64 = 0.0
    max_y::Float64 = 100.0
    light_loc::Float64 = 10.0
    sigma::Function = y->abs(y - light_loc) + 1e-4
end

POMDPs.discount(p::LightDarkPOMDP) = p.discount_factor
POMDPs.isterminal(::LightDarkPOMDP, act::Int64) = act == 0
POMDPs.isterminal(::LightDarkPOMDP, s::LightDarkState) = s.status < 0
POMDPs.actions(::LightDarkPOMDP) = -1:1

struct LDNormalStateDist
    mean::Float64
    std::Float64
end

POMDPModels.sampletype(::Type{LDNormalStateDist}) = LightDarkState
Base.rand(rng::AbstractRNG, d::LDNormalStateDist) = LightDarkState(0, d.mean + randn(rng)*d.std)
Base.rand(rng::AbstractRNG, d::LDNormalStateDist, n::Int) = LightDarkState[rand(rng, d) for _ in 1:n]
Base.rand(d::LDNormalStateDist) = rand(Random.GLOBAL_RNG, d)
Base.rand(d::LDNormalStateDist, n::Int) = rand(Random.GLOBAL_RNG, d, n)
POMDPs.initialstate(pomdp::LightDarkPOMDP) = LDNormalStateDist(2, 3)
POMDPs.initialobs(m::LightDarkPOMDP, s) = observation(m, s)

POMDPs.observation(p::LightDarkPOMDP, sp::LightDarkState) = Normal(sp.y, p.sigma(sp.y))

function POMDPs.transition(p::LightDarkPOMDP, s::LightDarkState, a::Int)
    status = (a == 0) ? -1 : s.status
    y = clamp(s.y + a*p.step_size, -p.max_y, p.max_y)
    return Deterministic(LightDarkState(status, y))
end

function POMDPs.reward(p::LightDarkPOMDP, s::LightDarkState, a::Int)
    if s.status < 0
        return 0.0
    elseif a == 0
        if abs(s.y) < 1
            return p.correct_r
        else
            return p.incorrect_r
        end
    else
        return -p.movement_cost
    end
end

POMDPs.convert_s(::Type{A}, s::LightDarkState, p::LightDarkPOMDP) where A<:AbstractArray = eltype(A)[s.status, s.y]
POMDPs.convert_s(::Type{LightDarkState}, s::A, p::LightDarkPOMDP) where A<:AbstractArray = LightDarkState(Int64(s[1]), s[2])

@with_kw mutable struct ParticleHistoryBelief
    particles::ParticleCollection
    observations::Vector = []
    actions::Vector = []
end

@with_kw mutable struct ParticleHistoryBeliefUpdater <: Updater
    pf::Updater
end

function POMDPs.update(up::ParticleHistoryBeliefUpdater, b::ParticleHistoryBelief, a, o)
    particles = update(up.pf, b.particles, a, o)
    observations = push!(deepcopy(b.observations), o)
    actions = push!(deepcopy(b.actions), a)
    return ParticleHistoryBelief(particles, observations, actions)
end

function POMDPs.initialize_belief(up::ParticleHistoryBeliefUpdater, d)
    particles = initialize_belief(up.pf, d)
    return ParticleHistoryBelief(; particles)
end

function Base.rand(rng::AbstractRNG, b::ParticleHistoryBelief, n::Integer=1)
    if n == 1
        return rand(rng, particles(b))
    else
        return rand(rng, particles(b), n)
    end
end

ParticleFilters.particles(b::ParticleHistoryBelief) = particles(b.particles)
ParticleFilters.support(b::ParticleHistoryBelief) = particles(b)

POMDPs.initialstate_distribution(pomdp::LightDarkPOMDP) = initialstate(pomdp) # deprecated in POMDPs v0.9

end # module LightDark
