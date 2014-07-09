------------------------------------------------------------------------
--[[ BlockSparse ]]--
-- A n-layer model for Distributed Conditional Computation
------------------------------------------------------------------------
local BlockSparse, parent = torch.class("dp.BlockSparse", "dp.Layer")
BlockSparse.isBlockSparse = true

function BlockSparse:__init(config)
   assert(type(config) == 'table', "Constructor requires key-value arguments")
   local args, input_size, n_block, hidden_size, window_size, gater_size, 
      output_size, noise_std, gater_act, expert_act, threshold_lr, 
      alpha_range, sparse_init, typename = xlua.unpack(
      {config},
      'BlockSparse', 
      'Deep mixture of experts model. It is three parametrized '..
      'layers of gated experts. There are n-1 gaters, one for each '..
      'layer of hidden neurons between nn.BlockSparses.',
      {arg='input_size', type='number', req=true,
       help='Number of input neurons'},
      {arg='n_block', type='table', req=true,
       help='number blocks in hidden layers between nn.BlockSparses.'},
      {arg='hidden_size', type='table', req=true,
       help='number of neurons per block in hidden layers between nn.BlockSparses.'},
      {arg='window_size', type='table', req=true,
       help='number of blocks used per example in each layer.'},
      {arg='gater_size', type='table', req=true,
       help='number of neurons in gater hidden layers'},
      {arg='output_size', type='number', req=true,
       help='output size of last layer'},
      {arg='noise_std', type='number', req=true,
       help='std deviation of gaussian noise used for NoisyReLU'},
      {arg='gater_act', type='nn.Module', default='',
       help='gater hidden activation. Defaults to nn.Tanh()'},
      {arg='expert_act', type='table', default='',
       help='expert activation. Defaults. to nn.Tanh()'},
      {arg='threshold_lr', type='number', default=0.1,
       help='learning rate to get the optimum threshold for a desired sparsity'},
      {arg='alpha_range', type='table', default='',
       help='{start_alpha, num_batches, endsall}'},
      {arg='sparse_init', type='boolean', default=false,
       help='sparse initialization of weights. See Martens (2010), '..
       '"Deep learning via Hessian-free optimization"'},
      {arg='typename', type='string', default='BlockSparse', 
       help='identifies Model type in reports.'}
   )
   self._input_size = input_size
   self._output_size = output_size
   self._gater_size = gater_size
   self._n_block = n_block
   self._hidden_size = hidden_size
   self._window_size = window_size
   alpha_range = (alpha_range == '') and {0.5, 1000, 0.01} or alpha_range
   gater_act = (gater_act == '') and nn.Tanh() or gater_act
   expert_act = (expert_act == '') and nn.Tanh() or expert_act
   
   -- experts
   self._experts = {}
   local para = nn.ParallelTable()
   para:add(expert_act:clone())
   para:add(nn.Identity())
   
   local expert = nn.Sequential()
   expert:add(nn.BlockSparse(1, self._input_size, self._n_block[1], self._hidden_size[1], config.acc_update))
   expert:add(para)
   table.insert(self._experts, expert)
   
   for i=1,#self._n_block - 1 do
      expert = nn.Sequential()
      expert:add(nn.BlockSparse(self._n_block[i], self._hidden_size[i], self._n_block[i+1], self._hidden_size[i+1], config.acc_update))
      expert:add(para:clone())
      table.insert(self._experts, expert)
   end
   
   local dept = #self._n_block
   expert = nn.Sequential()
   expert:add(nn.BlockSparse(self._n_block[dept], self._hidden_size[dept], 1, output_size, config.acc_update))
   expert:add(expert_act:clone())
   table.insert(self._experts, expert)
   
   -- gaters
   self._gates = {}
   
   self._gater = nn.Sequential()
   local inputSize = self._input_size
   for i, gater_size in ipairs(self._gater_size) do
      self._gater:add(nn.Linear(inputSize, self._gater_size[i]))
      self._gater:add(gater_act:clone())
      inputSize = self._gater_size[i]
   end
   
   local concat = nn.ConcatTable()
   self._relus = {}
   for i=1,#self._window_size do
      local gate = nn.Sequential()
      gate:add(nn.Linear(self._gater_size[#self._gater_size], self._n_block[i]))
      local relu = nn.NoisyReLU(self._window_size[i]/self._n_block[i], threshold_lr, alpha_range, noise_std[i])
      gate:add(relu)
      table.insert(self._relus, relu)
      gate:add(nn.LazyKBest(self._window_size[i]))
      concat:add(gate)
      table.insert(self._gates, gate)
   end
   self._gater:add(concat)
   
   -- mixture
   self._module = nn.BlockMixture(self._experts, self._gater)
   
   config.typename = typename
   config.output = dp.DataView()
   config.input_view = 'bf'
   config.output_view = 'bf'
   config.tags = config.tags or {}
   config.sparse_init = sparse_init
   parent.__init(self, config)
   -- only works with cuda
   self:type('torch.CudaTensor')
end

function BlockSparse:sharedClone()
   error"NotImplemented"
end

function BlockSparse:_zeroStatistics()
   self._stats.std = torch.FloatTensor(#self._window_size):zero()
   self._stats.mean = torch.FloatTensor(#self._window_size):zero()
end

function BlockSparse:_updateStatistics()
   for i, relu in ipairs(self._relus) do
      self._stats.std[i] = 0.9*self._stats.std[i] + 0.1*relu.sparsity:std()
      self._stats.mean[i] = 0.9*self._stats.mean[i] + 0.1*relu.sparsity:mean()
   end
end

function BlockSparse:report()
   print(self:name())
   local msg = "mean+-std "
   for i=1,self._stats.mean:size(1) do
      msg = msg..self._stats.mean[i].."+-"..self._stats.std[i].." "
   end
   print(msg)
end
