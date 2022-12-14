function [K1, K0, K2] = tuneVestibularLinear(B, I, S, conds, tts,sines,...
    R, RR_data, S_pc, S_eye, R_pc, R_eye, PF)
% [K1, K0, K2] = tuneVestibularLinear(B, I, S, R, mask_learn, conds, tts,...
%     R, RR_data, S_pc, S_eye, R_pc, R_eye)
% Initial linear fit for vestibular weights. 
%% ======================= PRE-LEARNING ===============================
% Only look at low frequencies (which have both eye and PC data) for now (fine tune later)
sine_mask = repelem(sines, cellfun(@length,tts));
mask_lo = sine_mask<=10; 

% Add regularization penalty
n_eye = length(R.reg_weights_eye);
X_eye = [S_eye(mask_lo,:); I.reg_lambda0*R.T0_eye; I.reg_lambda1*R.T1_eye; I.reg_lambda2*R.T2_eye]; % Penalize curvature
Y_eye = [R_eye(mask_lo); zeros(3*n_eye,1)];

% Constrain head velocity filters
beq_eye = zeros(n_eye, 1);
Aeq_eye = zeros(n_eye,1);

% Upper and lower bounds
lb_eye = -inf(n_eye, 1);
ub_eye = inf(n_eye, 1);

if I.restrict_EP_pos
    lb_eye(B.bEP_maskE) = 0;
end

% Solve for eye coefficients
Kb_eye = lsqlin(X_eye, Y_eye,[],[], diag(Aeq_eye), beq_eye, lb_eye, ub_eye, [], optimset('display','off','Algorithm','interior-point'));

% g1 is the net strength of K_EP. Use to scale K_PE so that K_EP*K_PE = I.PFs(ii).
K_EP = B.B_EP*Kb_eye(B.bEP_maskE)*S.scale_P;
g1 = sum(K_EP); % g1*g2 = I.PFs(ii) --> g2 = I.PFs(ii)/g1

%  ******* Purkinje cell fit *******
n_pc = length(R.reg_weights_pc);
X_reg = [I.reg_lambda0*R.T0_pc; I.reg_lambda1*R.T1_pc;  I.reg_lambda2*R.T2_pc]; % EDIT 6/25 remove I.scale_PH
Y_reg = zeros(3*n_pc,1);

X_pc = [S_pc(mask_lo,:); X_reg];
Y_pc = [R_pc(mask_lo); Y_reg];

% Fix the positive feedback weight to I.PFs(ii)
Aeq_pc = double(B.bPE_maskP);
beq_pc = zeros(n_pc, 1);
beq_pc(B.bPE_maskP) = PF/g1; % g1 is the sum of weights kEP

% Lower and upper bounds
lb_pc = -inf(n_pc,1);
ub_pc = inf(n_pc,1);

if I.restrict_PT_pos  % constrain predictive target weights positive
    lb_pc(B.bPT_vel_maskP | B.bPT_acc_maskP | B.bPT_vel_step_maskP | B.bPT_acc_step_maskP ) = 0;
end

% For PF = 1 only, don't allow predictive target velocity for steps (causes instability)
if PF == 1 && I.include_T_step
    lb_pc(B.bPT_vel_step_maskP) = 0;
    ub_pc(B.bPT_vel_step_maskP) = 0;
end

% Solve for PC coefficients
Kb_pc = lsqlin(X_pc, Y_pc,[],[], diag(Aeq_pc), beq_pc, lb_pc, ub_pc, [], optimset('display','off','Algorithm', 'interior-point'));


% Multiply coefficients by bases to get filters in time domain
K1 = updateK(B, I, S, Kb_eye, Kb_pc);

% Plot linear fit predictions of eye and PC
[err_eye, err_pc, Ehat_linear, Phat_linear] = plotLinearPredictions(S_eye(mask_lo,:), S_pc(mask_lo,:),R_eye(mask_lo), R_pc(mask_lo),  Kb_eye, Kb_pc);




%% =======================  POST-LEARNING ===============================
% Mask for artificial steps (used to fit steady state conditions)
step_mask_all =  repelem(strcmp(conds,'step'), cellfun(@length,tts));

% Mask for 0.5 Hz dark condition
Hz05_dark_mask = repelem(strcmp(conds,'05Hz_dark'), cellfun(@length, tts)); 

% Mask/index for Ramachandran and Lisberger frequency conditions
ind_sines_RR = repelem([zeros(I.nConds_JR,1); (1:length(RR_data.freqs))'; iif(I.include_step,0)], cellfun(@length,tts));


% Mask for learning params
mask_learn = B.learn_mask_vest_eye_pc;
eye_learn_mask = mask_learn(1:length(B.bEH_maskE));
pc_learn_mask = mask_learn(length(B.bEH_maskE)+1:end);

% Get original gain and phase
[~, ~, E_gain_orig, E_phase_orig, P_gain_orig, P_phase_orig] = getFreq(K1, I, RR_data.freqs);

% Combining SL and Watanabe
pc_ss = I.pc_gain_ss + I.pc_ss.*(1-I.eye_ss);
% basline sp/s + change in sp/s per change in deg/s * change in gain (norm
% by ratio of JR and SL baseline gains. Order: [Low Normal High]. 

for type = [0 2]

% Assign parameters specific to x0 or x2
PC_gain_new = pc_ss(type+1); % type: 0:'x0',1:'x1',2:'x2'

if type==2 % Gain up
    RR_eye_gain_new = RR_data.gains2;
    RR_eye_phase_new = RR_data.phases2;
else
    RR_eye_gain_new = RR_data.gains0;
    RR_eye_phase_new = RR_data.phases0;
end

% Mask out the early step time points that don't matter

step_mask = tts{strcmp(conds,'step')}>I.T_step_ss;
temp = find(step_mask_all);
R_pc(temp(~step_mask)) = 0; 
S_pc(temp(~step_mask),:) = 0;
 
R_eye(temp(~step_mask)) = 0; 
S_eye(temp(~step_mask),:) = 0;

%% LEARNING: PC
% Use linear fit similar to linear baseline fit but with penalty for deviation
% from original weights

% Create goal PC output - step and 0.5 Hz sine VORD only
R_pc_learn = R_pc(step_mask_all | Hz05_dark_mask);
S_pc_learn = S_pc(step_mask_all | Hz05_dark_mask,:);

% Update the desired PC activity 
R_pc_learn = PC_gain_new/I.pc_gain_ss*R_pc_learn;

% Update the learned eye velocity input
S_pc_learn(:,B.bPE_maskP) = RR_eye_gain_new(1)/RR_data.gains1(1)*S_pc_learn(:,B.bPE_maskP); % Replace old eye efference with new eye after learning

% Create regularization penalty for deviation from original weights
X_pc = [S_pc_learn; I.scale_learn*[I.reg_lambda0*R.T0_pc;  I.reg_lambda1*R.T1_pc;  I.reg_lambda2*R.T2_pc] ];
Y_pc = [R_pc_learn; I.scale_learn*[I.reg_lambda0*R.T0_pc*K1.Kb_pc; I.reg_lambda1*R.T1_pc*K1.Kb_pc; I.reg_lambda2*R.T2_pc*K1.Kb_pc] ];

% Fix non-plastic weights
Aeq_diag = ~pc_learn_mask;
beq_eye = K1.Kb_pc;
beq_eye(pc_learn_mask) = 0; 
Aeq_eye = double(diag(Aeq_diag));

% Set upper and lower bounds
lb = -inf(size(K1.Kb_pc));
ub = inf(size(K1.Kb_pc));

% Constrain the direction of plasticity at kPH for EVERY coefficient
% if I.fixPH==1       % Only LTP
%     lb(B.bPH_maskP) = K1.Kb_pc(B.bPH_maskP);
% elseif I.fixPH==-1  % Only LTD
%     ub(B.bPH_maskP) = K1.Kb_pc(B.bPH_maskP);
% end

% Constrain the NET direction of plasticity
A_ineq = -I.fixPH*(B.bPH_maskP);
A_ineq = A_ineq(any(A_ineq,2),:);
B_ineq = -I.fixPH*sum(K1.Kb_pc(B.bPH_maskP))*ones(size(A_ineq,1),1);   % New net weight has to be less than or greater than old net weight

% Fit PC activity vestibular weights
[Kb_pc_learn,resnorm,residual,exitflag,output,lambda] = lsqlin(...
    X_pc, Y_pc, A_ineq, B_ineq, Aeq_eye, beq_eye, lb, ub, [], optimset('Algorithm','interior-point','Display','off'));



%% 2 LEARNING: EYE 
% Select conditions for eye: all frequencies from 0.5 to 50 Hz
hevel_new = cell(length(RR_data.freqs),1);
hhvel_SL = cell(length(RR_data.freqs),1);
for jj = 1:length(RR_data.freqs)
    gain_goal(jj)  = RR_eye_gain_new(jj)/RR_data.gains1(jj) * E_gain_orig(jj);
    phase_goal(jj) = RR_eye_phase_new(jj) - RR_data.phases1(jj) + E_phase_orig(jj);
    
    T_temp = round(2*RR_data.freqs(jj))/RR_data.freqs(jj); % Max time - should be a multiple of sine period
    tt = K1.dt*(1:round(T_temp/K1.dt))'-K1.dt;
    hhvel_SL{jj} = sin(2*pi*RR_data.freqs(jj)*tt);
    hevel_new{jj} =  I.amp*gain_goal(jj)*sin(2*pi*RR_data.freqs(jj)*tt + phase_goal(jj)*pi/180);
end

% Fill in eye prediction - output
R_eye_learn =cell2mat(hevel_new(:));

%TODO: make sure steps are included!

% Fill in PC prediction - input
for jj = 1:length(RR_data.freqs)
    
    % Split it up into segments
    curr_mask = ind_sines_RR==jj; % time indix into all data
    
    % Update the eye efference input to PC 
    e_vel_new = filterExponential(I.tauPE, K1.dt, hevel_new(jj), 1);
    S_pc(curr_mask, B.bPE_maskP) = e_vel_new{1};
    
    % Use above fit to predict what PC should be for missing values
    PC_predict = S_pc(curr_mask,:)*Kb_pc_learn;
    
    % Extend to history matrix
    PC_predict_mat = makeHistoryMatrix(PC_predict, max(size(B.B_PH,1),size(B.B_EP,1)), 1);
    
    % Fill in the missing PC data
    S_eye(curr_mask, B.bEP_maskE) = PC_predict_mat(:,1:size(B.B_EP,1))*B.B_EP; % TODO check this!! Removed *S.scale_P EDIT 6/25/19
    
end

% Add the step prediction from PC
S_eye(step_mask_all, B.bEP_maskE) = PC_gain_new/I.pc_gain_ss*S_eye(step_mask_all, B.bEP_maskE);

% Select the Ramachandran & Lisberger data frequency component
S_eye_SL = S_eye(ind_sines_RR>0, :);

% Create regularization for eye - R.T_eye was already scaled by this
X_eye = [S_eye_SL;
    I.scale_learn*[I.reg_lambda0*R.T0_eye;   ...
    I.reg_lambda1*R.T1_eye;    I.reg_lambda2*R.T2_eye] ];
Y_eye  = [R_eye_learn;...
    I.scale_learn*[I.reg_lambda0*R.T0_eye*K1.Kb_eye;...
    I.reg_lambda1*R.T1_eye*K1.Kb_eye; I.reg_lambda2*R.T2_eye*K1.Kb_eye] ];

% Fix kEP weights and only allow head inputs to
Aeq_diag = ~eye_learn_mask;
beq_eye = K1.Kb_eye;
beq_eye(eye_learn_mask) = 0; 
Aeq_eye = double(diag(Aeq_diag));


% Set upper and lower bounds
lb_eye = -inf(size(K1.Kb_eye));
ub_eye = inf(size(K1.Kb_eye));

% Constrain the direction of plasticity at kPH 
if I.fixB       % No plasticity in brainstem
    lb_eye(B.bPH_maskP) = K1.Kb_eye(B.bEH_maskE);
    ub_eye(B.bPH_maskP) = K1.Kb_eye(B.bEH_maskE);
end

% Solve for eye coefficients
Kb_eye_learn = lsqlin(X_eye, Y_eye,[],[], Aeq_eye, beq_eye, lb_eye, ub_eye,[],optimset('Algorithm','interior-point','Display','off'));

% Store the filters in time domain for this PF strength
Knew = updateK(B, I, S, Kb_eye_learn, Kb_pc_learn);
if type==0
    K0 = Knew;
elseif type==2
    K2 = Knew;
end

end


