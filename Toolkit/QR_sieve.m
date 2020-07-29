% This version
% This codes gives a start value to piecewise linear MLE simulations.
% This version uses GA, instead of fmincon
% Haoyang Liu
% 12/09/2018
function [betas, fit_hat, betas_bootstrap, fit_hat_bootstrap] = ...
    QR_sieve(X, y, ntau, n_WLS_iter, upper, lower, nmixtures, ...
    do_mle, optimizer, bootstrap, make_plot)

% TODO: Add bootstrapping, saving only full result in array. Like fit_hat
% only.

% Generate the grid of knots for tau

% taugrid is the old tau grid for quantile regression
% taugrid_midpoint is the mid point of tau segments
% taugrid_ue is the new uneven grid

% Question: Currently taugrid_midpoint is not used. Is there another
% formulation where we use the midpoints and that's why it's calculated?
% Answer: taugrid_midpoint is used to plot the results of the WLS
% regression


[taugrid, ~, taugrid_ue] = calculate_grid(ntau);

nsample = size(X,1);
ncovar = size(X,2);

% nvars is the total number of parameters
nvars = ncovar*ntau+3*nmixtures-2;
% Note: the 3 is because for each mixture we estimate (1) the mean, (2) the
% weight, and (3) the std dev. The -2 is because one mean and one weight
% are pinned down by the other ones.

% Constants
b=1;
A = zeros(1,nvars);
A(ncovar*ntau+1:ncovar*ntau+nmixtures-1) = 1;

lower=[zeros(1,(ncovar*ntau))+lower(1), (zeros(1,(nmixtures-1))+lower(2)), ...
    (zeros(1,(nmixtures-1))+lower(3)),(zeros(1,nmixtures)+lower(4))];

upper=[zeros(1,(ncovar*ntau))+upper(1), (zeros(1,(nmixtures-1))+upper(2)), ...
    (zeros(1,(nmixtures-1))+upper(3)),(zeros(1,nmixtures)+upper(4))];


% define the starting values for the guess of distributional parameters
if nmixtures == 1

elseif mod(nmixtures, 2) == 0
    lambda_start = repmat([1/nmixtures], 1, nmixtures-1);
    mu_start = [repmat([-1], 1, nmixtures/2), repmat([1], 1, nmixtures/2-1)];
    sigma_start = repmat([1], 1, nmixtures);
    para_dist_default = [lambda_start, mu_start, sigma_start];
else
    lambda_start = repmat([1/nmixtures], 1, nmixtures-1);
    mu_start = [repmat([-1], 1, (nmixtures-1)/2), 0, repmat([1], 1, (nmixtures-1)/2-1)];
    sigma_start = repmat([1], 1, nmixtures);
    para_dist_default = [lambda_start, mu_start, sigma_start];
end

X_mean = mean(X);

% Part E) qreg and WLS
[fit] = quantlsfVector(X,y,taugrid);
WLS =  WLS_step(fit,X,y,n_WLS_iter);

if do_mle

    % Part F) MLE
    start = [WLS, para_dist_default];
    % TODO: Unfreeze the minimizing function
    options=optimoptions(@fmincon,'GradObj','on');
    [fit_hat] = fmincon(@(x)gradllfCovarparavector(x, ntau, nmixtures,1,y, X),start,A,b,[],[],lower,upper,[],options);
    disp("Finished first MLE")
    betas = (reshape(fit_hat(1,[1:(ncovar*ntau)]), [ntau, ncovar]))';


    % G) Piecewise linear MLE
    % G-1) Sort piecewise constant result
    WLS_start_reshape = reshape(fit_hat(1:ntau*ncovar),ntau,ncovar);
    [beta_WLS_start_sorted] = sortbeta_1(X_mean,WLS_start_reshape,ntau,ncovar);
    beta_WLS_start_sorted = beta_WLS_start_sorted';

    % G-2) Construct the start value
    [fit_1_temp] = construct_pl_start(beta_WLS_start_sorted, ncovar, ntau);
    start = [fit_1_temp, fit_hat([(end - 3*nmixtures + 3) : end])];
    start(end-2:end)

    if optimizer{1} == "GA"

        opts = optimoptions('ga', 'MaxGenerations', optimizer{2}, 'PopulationSize', optimizer{3});
        opts.InitialPopulationMatrix = start;
        [fit_hat] = ga(@(x)gradl_CDF_Lei_GA_ue(x, taugrid_ue, nmixtures, y', X'), nvars, A, b,[],[],lower,upper,[],opts);

    elseif optimizer{1} == "SGD"

        n_batches = optimizer{2};
        n_epochs = optimizer{3};
        learning_rate = optimizer{4};
        decay = optimizer{5};
        verbose = optimizer{6};

        f = @(x,y,X) gradl_CDF_Lei_GA_ue(x, taugrid_ue, nmixtures, y', X');
        [fit_hat] = sgd(f, start, y, X, n_batches, n_epochs, learning_rate, decay, verbose);
        
    elseif optimizer{1} == "Custom"
        
        %TODO: List requirements for custom optimizer here

        f = @(x,y,X) gradl_CDF_Lei_GA_ue(x, taugrid_ue, nmixtures, y', X');
        fit_hat = optimizer{2}(f, start, y, X);

    end

    betas = reconstruct_beta((reshape(fit_hat(1,[1:(ncovar*ntau)]), [ntau, ncovar]))');
    disp("Finished second MLE")

else

    disp("Returning results from WLS regression.")
    betas = WLS;
    fit_hat = WLS;

end

fit_hat_bootstrap = fit_hat;
betas_bootstrap = betas;
    
if bootstrap > 1
    if optimizer{1} == "SGD"
        optimizer{6} = false;
    end
    sample_size = floor(nsample / bootstrap);
    fit_hat_bootstrap = zeros(bootstrap, nvars);
    betas_bootstrap = zeros(ncovar, ntau, bootstrap);
    parfor i = 1:bootstrap
        sample_index = randsample(1:nsample, sample_size);
        y_sample = y(sample_index);
        X_sample = X(sample_index, :);
        [betas_subsample, fit_hat_subsample] = QR_sieve(X_sample, y_sample, ntau, n_WLS_iter, ...
            upper, lower, nmixtures, do_mle, optimizer, 1, false);
        fit_hat_bootstrap(i,:) = fit_hat_subsample
        betas_bootstrap(:,:,i) = betas_subsample
    end
    if make_plot
        betas_std = std(betas_bootstrap, 0, 3);
        for i = 1:ncovar
            figure()
            hold on
            plot(taugrid_ue, betas(i,:), 'LineWidth', 2)
            plot(taugrid_ue, betas(i,:) + 1.96 * betas_std(i,:), 'LineWidth', 2)
            plot(taugrid_ue, betas(i,:) - 1.96 * betas_std(i,:), 'LineWidth', 2)
            xlabel('$\tau$', 'interpreter', 'latex', 'FontSize', 16)
            ylabel_text = sprintf("$\\beta_{%d}(\\tau)$", i);
            ylabel(ylabel_text, 'interpreter', 'latex', 'FontSize', 16);
        end
        
        lambdas_short = fit_hat(ncovar*ntau+1:ncovar*ntau+nmixtures-1);
        lambdas = [lambdas_short, 1 - sum(lambdas_short)];
        mus_short = fit_hat(ncovar*ntau+nmixtures:ncovar*ntau+2*nmixtures-2);
        mus = [mus_short, -sum(lambdas_short.*mus_short)/lambdas(end)];
        sigmas = fit_hat(nvars-2:nvars);
        
        dom_min = min(mus - 3 * sigmas);
        dom_max = max(mus + 3 * sigmas);
        n_points = 100;
        dom = linspace(dom_min, dom_max, n_points);
        
        density_y = zeros(1,n_points);
        
        for i = 1:nmixtures
            density_y = density_y + lambdas(i) * normpdf(dom, mus(i), sigmas(i));
        end
        
        density_dist = zeros(bootstrap,n_points);
        
        parfor j = 1:bootstrap
            lambdas_short = fit_hat_bootstrap(j,ncovar*ntau+1:ncovar*ntau+nmixtures-1);
            lambdas = [lambdas_short, 1 - sum(lambdas_short)]
            mus_short = fit_hat_bootstrap(j,ncovar*ntau+nmixtures:ncovar*ntau+2*nmixtures-2);
            mus = [mus_short, -sum(lambdas_short.*mus_short)/lambdas(end)]
            sigmas = fit_hat_bootstrap(j,nvars-2:nvars)
            for i = 1:nmixtures
                density_dist(j,:) = density_dist(j,:) + lambdas(i) * normpdf(dom, mus(i), sigmas(i));
            end
        end
        
        density_std = std(density_dist);
        
        figure()
        hold on;
        plot(dom, density_y)
        xlabel('Measurement Error', 'FontSize', 16)
        ylabel('Density', 'FontSize', 16);
        plot(dom, density_y + 1.96 * density_std, 'LineWidth', 2)
        plot(dom, density_y - 1.96 * density_std, 'LineWidth', 2)
    end
    
else
    if make_plot
        for i = 1:ncovar
            figure()
            plot(taugrid_ue, betas(i,:), 'LineWidth', 2)
            xlabel('$\tau$', 'interpreter', 'latex', 'FontSize', 16)
            ylabel_text = sprintf("$\\beta_{%d}(\\tau)$", i);
            ylabel(ylabel_text, 'interpreter', 'latex', 'FontSize', 16);
        end
        
        lambdas_short = fit_hat(ncovar*ntau+1:ncovar*ntau+nmixtures-1);
        lambdas = [lambdas_short, 1 - sum(lambdas_short)];
        mus_short = fit_hat(ncovar*ntau+nmixtures:ncovar*ntau+2*nmixtures-2);
        mus = [mus_short, -sum(lambdas_short.*mus_short)/lambdas(end)];
        sigmas = fit_hat(end-2:end);
        
        dom_min = min(mus - 3 * sigmas);
        dom_max = max(mus + 3 * sigmas);
        n_points = 100;
        dom = linspace(dom_min, dom_max, n_points);
        
        density_y = zeros(1,n_points);
        
        for i = 1:nmixtures
            density_y = density_y + lambdas(i) * normpdf(dom, mus(i), sigmas(i));
        end
        
        figure()
        plot(dom, density_y, 'LineWidth', 2)
        xlabel('Measurement Error', 'FontSize', 16)
        ylabel('Density', 'FontSize', 16);
    end
end