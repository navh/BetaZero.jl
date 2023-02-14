using Revise
using Parameters
using ParticleFilters
using POMDPModels
using POMDPs
using POMDPTools
using Plots; default(fontfamily="Computer Modern", framestyle=:box)
using Statistics
using BetaZero
using Flux

# import Base: +
# Base.:(+)(s1::LightDark1DState, s2::LightDark1DState) = LightDark1DState(s1.status + s2.status, s1.y + s2.y)
# Base.:(/)(s::LightDark1DState, i::Int) = LightDark1DState(s.status, s.y/i)

POMDPs.actions(::LightDark1D) = [-10, -5, -1, 0, 1, 5, 10] # -10:10

function POMDPs.transition(p::LightDark1D, s::LightDark1DState, a::Int)
    if a == 0
        return Deterministic(LightDark1DState(-1, s.y+a*p.step_size))
    else
        max_y = 20
        return Deterministic(LightDark1DState(s.status, clamp(s.y+a*p.step_size, -max_y, max_y)))
    end
end

function POMDPs.reward(p::LightDark1D, s::LightDark1DState, a::Int)
    if a == 0
        return s == 0 ? p.correct_r : p.incorrect_r
    else
        return -p.movement_cost
    end
end

pomdp = LightDark1D()
pomdp.movement_cost = 0.0
up = BootstrapFilter(pomdp, 1000)

@with_kw mutable struct HeuristicLightDarkPolicy <: POMDPs.Policy
    pomdp
    thresh = 0.1
end

function POMDPs.action(policy::HeuristicLightDarkPolicy, b::ParticleCollection)
    ỹ = mean(s.y for s in particles(b))
    if abs(ỹ) ≤ policy.thresh
        return 0
    else
        A = filter(a->a != 0, actions(pomdp))
        return rand(A)
    end
end

policy = RandomPolicy(pomdp)
# policy = HeuristicLightDarkPolicy(; pomdp)

S = []
A = []
O = []
B = []
R = []
for (s,a,o,b,r,sp,bp) in stepthrough(pomdp, policy, up, "s,a,o,b,r,sp,bp", max_steps=500)
    ỹ = mean(s.y for s in particles(b))
    push!(S, s)
    push!(A, a)
    push!(O, o)
    push!(B, b)
    push!(R, r)
    # @info s.y, a, r, ỹ
end

# using ColorSchemes
Y = map(s->s.y, S)
ymax = max(10, max(maximum(Y), abs(minimum(Y))))*1.5
xmax = max(length(S), 50)
plot(xlims=(1, xmax), ylims=(-ymax, ymax), size=(900,200), margin=5Plots.mm, legend=:outertopleft, xlabel="time", ylabel="state")
heatmap!(1:xmax, range(-ymax, ymax, length=100), (x,y)->sqrt(std(observation(pomdp, LightDark1DState(0, y)))), c=:grayC)
hline!([0], c=:green, style=:dash, label="goal")
# plot!(eachindex(S), O, mark=true, ms=2, c=:gray, mc=:black, msc=:white, label="observation")
plot!(eachindex(S), Y, c=:red, lw=2, label="trajectory")
scatter!(eachindex(S), O, ms=2, c=:black, msc=:white, label="observation")
display(plot!())

#========== BetaZero ==========#
# Interface:
# 1) BetaZero.input_representation(b) -> Vector or Matrix
#============= || =============#

function BetaZero.input_representation(b::ParticleCollection)
    Y = [s.y for s in particles(b)]
    μ, σ = mean(Y), std(Y)
    return Float32[μ, σ]
end


# Simpler MLP
function BetaZero.initialize_network(nn_params::BetaZeroNetworkParameters) # MLP
    @info "Using simplified MLP for neural network..."
    input_size = nn_params.input_size
    num_dense1 = 16
    num_dense2 = 8
    out_dim = 1

    return Chain(
        Dense(prod(input_size), num_dense1, relu),
        Dense(num_dense1, num_dense2, relu),
        Dense(num_dense2, out_dim),
        # Note: A normalization layer will be added during training (with the old layer removed before the next training phase).
    )
end

lightdark_accuracy_func(pomdp, b0, s0, final_action, returns) = returns[end] == pomdp.correct_r
lightdark_belief_reward(pomdp, b, a, bp) = mean(reward(pomdp, s, a) for s in particles(b))

solver = BetaZeroSolver(updater=up,
                        belief_reward=lightdark_belief_reward,
                        n_iterations=2,
                        n_data_gen=10_000,
                        n_holdout=100,
                        use_random_policy_data_gen=true,
                        use_onestep_lookahead_holdout=true,
                        data_gen_policy=HeuristicLightDarkPolicy(; pomdp),
                        collect_metrics=true,
                        verbose=true,
                        include_info=true,
                        accuracy_func=lightdark_accuracy_func)

solver.mcts_solver.n_iterations = 10 # TODO: More!!!!
solver.mcts_solver.exploration_constant = 100.0 # TODO: 100.0 ???
solver.onestep_solver.n_actions = 10
solver.onestep_solver.n_obs = 1
solver.network_params.n_samples = 1000
solver.network_params.input_size = (2,)
solver.network_params.verbose_plot_frequency = 20
solver.network_params.verbose_update_frequency = 20
solver.network_params.learning_rate = 0.0001
solver.network_params.batchsize = 128
solver.network_params.λ_regularization = 0.0
solver.network_params.normalize_target = true
# solver.network_params.loss_func = Flux.Losses.mse # Mean-squared error

policy = solve(solver, pomdp)
# # other_solver = OneStepLookaheadSolver(n_actions=100,
#                                 # n_obs=10)
# other_solver = solver.mcts_solver
# bmdp = BeliefMDP(pomdp, up, lightdark_belief_reward)
# policy = solve(other_solver, bmdp)

# # policy = HeuristicLightDarkPolicy(; pomdp)
# b0 = initialize_belief(up, [rand(initialstate(pomdp)) for _ in 1:up.n_init])
# s0 = rand(initialstate(pomdp))
# @time data, metrics = BetaZero.run_simulation(pomdp, policy, up, b0, s0; accuracy_func=lightdark_accuracy_func, collect_metrics=true, include_info=true, max_steps=1000); metrics.accuracy


if false
    init_network = BetaZero.initialize_network(solver)
    @time _B = [Float32.(BetaZero.input_representation(initialize_belief(up, [rand(initialstate(pomdp)) for _ in 1:up.n_init]))) for _ in 1:100]
    @time _B = cat(_B...; dims=2)

    @time returns0_init_network = init_network(_B)
    @time returns0 = policy.network(_B)

    # network = BetaZero.initialize_network(solver)
    # @time returns0 = network(_B)

    network = BetaZero.train_network(deepcopy(network), solver; verbose=true)

    histogram(returns0', label="learned model", alpha=0.5)
    histogram!(returns0', label="uninitialized model", alpha=0.5)
end
