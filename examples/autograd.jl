# TODO:
# Working with one Node type simplifies the code.
# Could be much simplified if we don't support higher derivatives:
# - no need for multiple tapes, merge_tapes.
# - no need for tape complete?
# Need to find a Julia way to register primitives and their gradients.
# Need to test second order derivatives.
# Need to test arrays.
# Need to solve the allocation / overwriting problem.

importall Base

"""
grad(fun, argnum=1) -> gradfun    

* fun: X->Y    
* gradfun: X->dX   

Returns a function which computes the gradient of `fun` with respect to
positional argument number `argnum`. The returned function takes the same
arguments as `fun`, but returns the gradient instead. The function `fun`
should be scalar-valued. The gradient has the same type as the argument.
"""
function grad(fun, argnum=1)
    function gradfun(args...; kwargs...)
        backward_pass(forward_pass(fun, args, kwargs, argnum)...)
    end
    return gradfun
end


### There are three interacting types to record operations:

"""
A Node is created:

1. in forward_pass for the argument we are taking gradient w.r.t.
2. in call for the output of a primitive operation.

When a Node is created, it pushes ReverseNodes with the same value
on each tape, and records pointers to each tape and its ReverseNode
in its `tapes` dictionary.  These ReverseNodes have uninitialized
parent_grad_ops and outgrads.

Ordinarily there is only one tape (unless we do higher order derivatives).
"""
type Node; value; tapes;                                        # field tapes is a Dict()
    function Node(value, tapes)                                 # arg tapes is an Array
        self = new(value, ObjectIdDict())                       # tapes: Dict{tape->reversenode}
        for tape in tapes
            new_rnode = ReverseNode(typeof(self), value)        # Q: do we need typeof here any more if we have a single Node type?  also why define self.Rnode in python?
            push!(tape, new_rnode)
            self.tapes[tape] = new_rnode
        end
        return self
    end
end

"""
ReverseNode is a plain type with four slots:

* `parent_grad_ops`: `call` fills this with (gradfun,parent) pairs for each Node argument.
* `outgrads`: used by backward_pass
* `node_type`: type of corresponding Node
* `node_value`: same value as corresponding Node
"""    
type ReverseNode; parent_grad_ops; outgrads; node_type; node_value; end
ReverseNode(node_type, node_value) = ReverseNode([], [], node_type, node_value)
sum_outgrads(rnode::ReverseNode)=sum(rnode.outgrads)            # TODO: does this work when grads are arrays?  maybe that is the reason for the strange python syntax, using the 0'th grad as the accumulator?

"CalculationTape is an array of ReverseNodes with a `complete` flag."
CalculationTape()=Any[]
iscomplete(a)=(!isempty(a) && a[end]==nothing)
complete!(a)=push!(a,nothing)                                   # Q: why do we need complete?

"""
Wraps a function so that its gradient can be specified and its invocation
can be recorded. For examples, see the docs.
"""
type Primitive; fun; grads; zero_grads; end

# Turn methods into functions that take Primitive as first arg?
Primitive(fun) = Primitive(fun, Dict{Int,Function}(), Set{Int}())

"""
forward_pass(fun, args, kwargs, argnum) -> (start_node, end_node, tape)

Wraps the `argnum`'th arg in a Node with an empty tape and calls `fun`
which returns another Node.  Both nodes and the tape are returned.  Note
that forward_pass is only called for the top level function, the internal
operations use regular `call`.  This is the only place where a tape is
created.  Multiple tapes only enter the picture for higher level derivatives.
"""    
function forward_pass(fun, args, kwargs, argnum)
    @show (fun, args, kwargs, argnum)
    tape = CalculationTape()                                    # Q: what is this for, when do we need multiple tapes?
    arg_wrt = args[argnum]                                      # Q: return grad wrt all args instead of a single one?
    start_node = new_node(safe_type(getval(arg_wrt)), Any[tape]) # Q: do we need safe_type and getval?
    args = Any[args...]                                         # This is to make args writable
    args[argnum] = merge_tapes(start_node, arg_wrt)             # Q: what does merge do? arg_wrt is not a node? it returns start_node here, is this for higher order derivatives?
    end_node = fun(args...; kwargs...)                          # TODO: add error handling.
    return start_node, end_node, tape
end

# forward_pass: ((N->N),X,K,I)->(N,N,T)
# deps: CalculationTape, new_node, safe_type, getval, merge_tapes
new_node(value, tapes)=Node(value, tapes)
safe_type(value) = isa(value, Integer) ? float(value) : value
getval(x) = isa(x, Node) ? x.value : x                          # Q: we strip Node, important for higher order derivatives.
merge_tapes(x,y) = x            # TODO: this should be a primitive, there is trickery in its gradient

# This is where the main action is:
# forward_pass wraps the relevant argument in a Node and calls the top level function.
# Inside the function whenever a Primitive is called with a Node arg, we end up here.
# call(p::Primitive) replaces arg Nodes with their values and calls p.fun.
# for each Node arg, if it is not in zero_grads, and its tape is not complete:
# we store (tape, i, parent_rnode) in array ops and keep track of unique tapes.
# After the call, we wrap result in a node with all unique tapes.
# for each (tape, i, parent_rnode) in ops:
# we call gradmaker on p with argnum=i
# we push (grad_p, parent_rnode) on parent_grad_ops of ReverseNode of result 

function call(p::Primitive, args...; kwargs...)
    argvals = Any[args...]
    ops = []
    tapes = Set()
    for (i, arg) in enumerate(args)
        if isa(arg, Node)
            argvals[i] = arg.value
            if i in p.zero_grads; continue; end                 # Q: who sets zero_grads, why?
            for (tape, parent_rnode) in arg.tapes               # Node.tapes is a Dict{Tape,Node}
                if !iscomplete(tape)                            # Q: why do we need iscomplete? high-order derivatives?
                    push!(ops, (tape, i, parent_rnode))         # ops should be called args or inputs!
                    push!(tapes, tape)                          
                end
            end
        end
    end
    result = p.fun(argvals...; kwargs...)
    # if isa(result, NotImplemented); return result; end        # Q: what's this for?  NotImplemented is a Python primitive!
    if !isempty(ops)
        result = new_node(result, tapes)
        for (tape, argnum, parent) in ops                       
            gradfun = gradmaker(p, argnum, result, args, kwargs) # Creates a node specific gradfun (dy->dx) with x,y in a closure by calling p.grads[argnum](y,x)
            rnode = result.tapes[tape]
            push!(rnode.parent_grad_ops, (gradfun, parent))
        end
    end
    return result
end


# Q: Can we get away with a single Node type?
# Q: Why do we need multiple tapes?  Hypothesis: for higher level derivatives.
# Q: If we build a tree, how do we prune non-parameter inputs?  (they won't have node types)
# Q: How do we get derivatives for multiple parameters (possibly wrapped up in one list)?

# OK, at this point we get:
# MethodError: `sin` has no method matching sin(::Node)
# It is time to implement primitive.

function gradmaker(p::Primitive, argnum, ans, args, kwargs)
    try 
        p.grads[argnum](ans, args...; kwargs...)
    catch e
        if isa(e, KeyError)
            name = p.fun.env.name
            if isempty(p.grads)
                error("Gradient of $name not yet implemented.")
            else
                error("Gradient of $name w.r.t. arg number $argnum not yet implemented.")
            end
        else
            throw(e)
        end
    end
end

defgrad(p::Primitive, gradmaker, argnum=1) = (p.grads[argnum] = gradmaker)
defgrads(p::Primitive, gradmaker, argnums) = (for argnum in argnums; defgrad(p, partial(gradmaker, argnum), argnum); end)
defgrad_is_zero(p::Primitive, argnums=(1,))= (for argnum in argnums; push!(p.zero_grads, argnum); end)



# TODO: what is partial, define it?
# TODO: what is primitive with aux, do we need it?
# TODO: NotImplemented, NoDerivativeNode?
# TODO: zeros_like

"""
backward_pass(start_node, end_node, tape) -> gradient wrt start_node.value
"""
function backward_pass(start_node, end_node, tape)
    # @show start_node
    # @show end_node
    # display(tape)
    # @show isa(end_node, Node)
    # @show haskey(end_node.tapes, tape)
    global _s, _e, _t
    _s, _e, _t = start_node, end_node, tape
    isa(end_node, Node) || warn("end_node is not a Node")
    haskey(end_node.tapes, tape) || warn("cannot find the tape")
    if !isa(end_node, Node) || !haskey(end_node.tapes, tape)    # This may happen if the function returns a constant, for example
        warn("Output seems independent of input. Returning zero gradient.")
        return zeros_like(start_node)
    end
    # if !isa(end_node, FloatNode)...  ## we don't have float nodes
    for node in tape                                            # tape is created by forw_pass
        node.outgrads = []
    end
    end_node.tapes[tape].outgrads = [1.0]                       # end_node.tapes[tape] is the ReverseNode corresponding to end_node::Node

    complete!(tape)
    cur_outgrad = nothing
    for node in tape[end-1:-1:1]                                # note the end-1 because we pushed nothing to complete
        if !isempty(node.outgrads)
            cur_outgrad = sum_outgrads(node)
            # TODO: @assert (type(new_node(getval(cur_outgrad))) == node.node_type) "Types are {0} and {1}" # TODO:.format(type(new_node(getval(cur_outgrad))), node.node_type)
            for (gradfun, parent) in node.parent_grad_ops
                # Q: Should not be necessary with a single node type:
                # og = cast_to_node_type(gradfun(cur_outgrad), parent.node_type, parent.node_value)
                og = gradfun(cur_outgrad)
                push!(parent.outgrads, og)
            end
        end
    end
    return cur_outgrad
end

# Type signatures for gradients:
# f: X->Y
# Primitive(f)=P: Node(X)->Node(Y)?
# gradmaker: (Y,X)->(dY->dX)
# grad: P -> (X->dX)
# defgrad: gradmaker -> Void (puts gradmaker in grads)

# Primitive definition:
# Q: should we ask for gradients right away?
# Q: can we do gradients without higher order functions?
# Q: we need a Node method, what else do we absolutely need?

_psin = Primitive(sin)
_pcos = Primitive(cos)
sin(x::Node)=_psin(x)
cos(x::Node)=_pcos(x)
# Instead of recording inputs and outputs explicitly, we hide it in closures for every call?
# We store pointers to all inputs and outputs!
defgrad(_psin, (y,x)->(dy->dy * _pcos(x)))                         # dJ/dx = dJ/dy * dy/dx
defgrad(_pcos, (y,x)->(dy->-dy * _psin(x)))

(start_node, end_node, tape) = forward_pass(sin, [1.0,], [], 1)
#show start_node # value:1.0, tapes:(tape=>tape[1])
#show end_node   # value:0.84, tapes:(tape=>tape[2])
#display(tape)
# type ReverseNode; parent_grad_ops; outgrads; node_type; node_value; end
# tape[1]: ReverseNode(Any[],Any[],Node,1.0)                                                                       
# tape[2]: ReverseNode(Any[((anonymous function),ReverseNode(Any[],Any[],Node,1.0))],Any[],Node,0.8414709848078965)

_gsin = grad(sin)
_gcos = grad(cos)
#show sin(1.0)
#show _gsin(1.0)
#show cos(1.0)
#show _gcos(1.0)

# Implement + for multi-input example:
_padd = Primitive(+)
defgrad(_padd, (c,a,b)->(g->g), 1)
defgrad(_padd, (c,a,b)->(g->g), 2)
(+)(a::Node,b::Node)=_padd(a,b)

# foo1(x)=sin(sin(x)+cos(x))
# (start_node, end_node, tape) = forward_pass(foo1, [1.0,], [], 1)
# goo1 = grad(foo1)
# @show foo1(1.0)
# @show goo1(1.0)

# foo3(x)=(a=sin(x);println(typeof(a));b=cos(x);return a)
# goo3 = grad(foo3)
# @show goo3(1.0)

foo2(x,y)=sin(x)+cos(y)
goo2 = grad(foo2)
goo22 = grad(foo2, 2)
@show goo2(1,2)
@show goo22(1,2)

# Q: who does array allocation for array gradients?

# Do we need this?  work-in-progress...
# 
# """
# ans, x correspond to the original output and input.
# gradfun is a function that takes dJ/dy and returns dJ/dx for non-arrays.
# """
# function unbroadcast(ans, x, gradfun, broadcast_idx=1)
#     # x is the argument that we're differentiating with respect to.
#     if isa(x, Array)
#         shape = size(x)
#         function new_fun(g)
#             result = gradfun(g)
#             while anp.ndim(result) > len(shape)
#                 result = anp.sum(result, axis=broadcast_idx)
#             end
#             for axis, size in enumerate(shape)
#                 if size == 1
#                     result = anp.sum(result, axis=axis, keepdims=True)
#                 end
#             end
#             assert anp.shape(result) == shape
#             return result
#         end
#     elseif isarray(ans)
#         new_fun(g) = sum(gradfun(g))
#     else
#         return gradfun
#     end
#     # new_fun.__name__ = "unbroadcast_{0}".format(gradfun.__name__)
#     return new_fun
# end

:ok

# Q: how does this handle a scalar input?

# Q: how does this handle multiple scalar inputs?

# Q: how does this handle arrays?

# Q: how do we deal with multi-input functions?  From numpy_grads.py:
# anp.multiply.defgrad(lambda ans, x, y : unbroadcast(ans, x, lambda g : y * g))
# anp.multiply.defgrad(lambda ans, x, y : unbroadcast(ans, y, lambda g : x * g), argnum=1)
# However see make_grad_matmul in the same file.

# Q: instead of overwriting call and defining Primitive, can we just define methods for Node arguments?
# In that case we'd have to keep grads in a global hash.
# And we'd have to deal with multiple dispatch, i.e. multiple derivatives for multiple methods.
# Julia primitives like methods, which and invoke find the method of a function appropriate for given argtypes.
# methods(f) simply returns f.env which is a method table.

# Function: [:fptr,:env::MethodTable,:code]
# MethodTable: [:name,:defs::Method,:cache,:cache_arg1,:cache_targ,:max_args,:kwsorter,:module]
# Method: [:sig,:va,:isstaged,:tvars,:func,:invokes,:next]

# the hash could define a gradient for each method or each function (use Function and ObjectIdDict)
# there is also the problem of interface, autograd solves this with closures, we'd need to find a way to store input/output
# in autograd, there is no gradient but a gradient maker which is invoked with x,y and creates a function on demand


### Need to find a Julia way to register primitives and their gradients.
# - call Primitive if any of the args is Node
# -- if we define f(a...) and call back f if no Node do we get infinite loop?
# -- what if f(a...) already defined?
# - in Python they just replace the whole function with Primitive?
# - in Julia we only define a method.
# - how do we handle multiple gradient methods for a function with multiple methods?
# - we need a way to wrap built-in functions as well as user defined ones as Primitives
# - gradient can be another method of the same function that starts with a Gradient dummy type
# - need to decide on the call signature
# - in that case the Primitive also can be a method with a Forward dummy type -- no: internal calls are normal.
# - we have a function and its existing methods
# -- we need to add methods to handle Node arguments
# -- we need to define gradients of different methods
# -- do we add a forward method for each argtype?
# ++ or do we have a single fallback method to handle nodes?
# -- so it has to be f(a...), a single method that strips Nodes and calls the regular method.
# -- if no Nodes, does not call itself, just gives an error -> solves infinite loop.
# -- what if f(a...) already defined?
# - write now defgrad defines grad for one argnum of one Primitive.
# -- python functions are actually methods.
# -- but we may have multiple methods with different argtypes that have different gradients!
# -- so currently Primitive corresponds to a Method, not a Function.
# -- going forward this is no problem, we just strip Node and call regular function, record operation.
# -- we need gradients defined potentially for each argnum of each method
# -- the output could be an array.  output type does not determine method.  only input types do.
# -- so gradient or gradient maker method needs all inputs with their types!
# -- right now p.grads[argnum] stores one gradient maker per argument position.  It should at least be grads[argtypes,argnum].