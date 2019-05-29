#!/usr/bin/env python
from __future__ import print_function

from scipy.stats import beta
from scipy.linalg import orth
import argparse
import os
import numpy as np
import torch
import torch.backends.cudnn as cudnn
import torch.nn as nn
import torch.optim as optim
import torchvision.transforms as transforms
import torchvision.datasets as datasets
import models
import datetime
import timeit
from torch.nn.modules.module import Module
from datetime import timedelta
import torch.nn.functional as F

ME_DIR = os.path.dirname(os.path.realpath(__file__))


class CrossEntropyLoss_SoftLabels(Module):
    def __init__(self, dim=None):
        super(CrossEntropyLoss_SoftLabels, self).__init__()
        self.dim = dim

    def __setstate__(self, state):
        self.__dict__.update(state)
        if not hasattr(self, 'dim'):
            self.dim = None

    def forward(self, predictions, soft_targets, underconfidence=False):
        logsoftmax = F.log_softmax(predictions, self.dim, _stacklevel=5)
        cross_entropy_loss = -torch.mean(torch.sum(soft_targets * logsoftmax, self.dim))
        if underconfidence:
            softmax_predictions = torch.nn.functional.softmax(predictions, dim=self.dim)
            prediction_entropy = torch.mean(torch.sum(- softmax_predictions * logsoftmax, self.dim))
            return cross_entropy_loss + 2 * prediction_entropy
        else:
            return cross_entropy_loss


class NegativeCosineLoss(Module):
    def __init__(self, dim=None):
        super(NegativeCosineLoss, self).__init__()
        self.dim = dim

    def __setstate__(self, state):
        self.__dict__.update(state)
        if not hasattr(self, 'dim'):
            self.dim = None

    def forward(self, predictions, soft_targets):
        output = -torch.mean(F.cosine_similarity(soft_targets, predictions))
        return output


if __name__ == '__main__':

    parser = argparse.ArgumentParser(description='PyTorch Mixup/DAT Training')
    parser.add_argument('--lr', default=0.1, type=float, help='learning rate')

    parser.add_argument('--dat_parameters', default=(2., 1.), type=float, nargs=2,
                        help='parameters of beta distribution used as family of pDAT distribution -- default is equivalent to mixup with uniform distribution, aka lam ~ pMIX = Beta(1,1). Only used if --dat_transform supplied.')
    parser.add_argument("--dat_transform",
                        help="use DAT transform to get lambda and gamma policy parameters, starting with the pDAT specified as a B(a,b) family where a, b supplied by --data_parameters arguments",
                        action="store_true")

    parser.add_argument('--gamma_parameters', default=(1., 1.), type=float, nargs=2,
                        help='parameters of gamma function (Beta CDF) -- default is mixup default of gamma=lambda. Only used if --dat_transform NOT supplied.')
    parser.add_argument('--lam_parameters', default=(1., 1.), type=float, nargs=2,
                        help='')

    # store_false defaults to true; store_true defaults to false https://stackoverflow.com/a/8203679/8112889
    parser.add_argument("--no_mixup", dest='mixup', help="disable mixup (default: enabled)", action="store_false")
    parser.add_argument("--sanity_learning_rate", help="use original author's learning rate drops at 100/150",
                        action="store_true")
    parser.add_argument("--stratified_sampling", help="stratify sampling of lambda", action="store_true")
    parser.add_argument("--decay_learning_rate", help="use experimental decay learning rate", action="store_true")
    parser.add_argument("--iid_sampling", help="sample the second datapoint as an i.i.d instead of batch-wise",
                        action="store_true")

    parser.add_argument("--directional_adversarial", help="enable directionarl adversarial training INSTEAD of mixup",
                        action="store_true")
    parser.add_argument('--checkpoint', type=str,
                        help='checkpoint from which to resume a simulation')
    parser.add_argument('--model', default="ResNet18", type=str,
                        help='model type (default: ResNet18)')
    parser.add_argument('--name', default='0', type=str, help='name of run')
    parser.add_argument('--dataset', default='cifar10', type=str, help='training samples dataset (default: cifar10)')
    parser.add_argument('--seed', type=int, help='random seed')
    parser.add_argument('--batch_size', default=128, type=int, help='batch size')
    parser.add_argument('--epoch', default=200, type=int,
                        help='total epochs to run (including those run in previous checkpoint)')
    parser.add_argument('--num_batches', default=200, type=int,
                        help='total batches to run (including those run in previous checkpoint)')
    parser.add_argument('--no_augment', dest='augment', action='store_false',
                        help='use standard augmentation (default: True)')
    parser.add_argument('--decay', default=1e-4, type=float, help='weight decay')

    parser.add_argument("--cosine_loss", help="train with cosine loss instead of cross entropy (default: disabled)", action="store_true")
    parser.add_argument('--label_dim', default=300, type=int, help='dimension of label embedding')

    args = parser.parse_args()

    print(datetime.datetime.now().strftime("START SIMULATION: %Y-%m-%d %H:%M"))
    sim_time_start = timeit.default_timer()

    start_epoch = 0  # start from epoch 0 or last checkpoint epoch

    print("ARGUMENTS:")
    for arg in vars(args):
        print(arg, getattr(args, arg))

    if args.seed:
        SEED = args.seed
    else:
        SEED = np.random.randint(1)
        print("Random seed: ", SEED)
    np.random.seed(SEED)
    torch.manual_seed(SEED)

    use_cuda = torch.cuda.is_available()
    if use_cuda:
        device = torch.device("cuda:0")
        torch.cuda.manual_seed(SEED)
        cudnn.deterministic = True
        cudnn.benchmark = False
    else:
        device = torch.device("cpu")

    if args.dataset == 'cifar10':
        num_classes = 10
        normalize_transform = transforms.Normalize((0.4914, 0.4822, 0.4465), (0.2470, 0.2435, 0.2612))
    elif args.dataset == 'cifar100':
        num_classes = 100
        normalize_transform = transforms.Normalize((0.5071, 0.4865, 0.4409), (0.2673, 0.2564, 0.2762))
    elif args.dataset == 'mnist':
        num_classes = 10
        # TODO: ADD SUPPORT (normalize transform + verify cropping)
    elif args.dataset == 'mnist_fashion':
        num_classes = 10
        # TODO: ADD SUPPORT (normalize transform + verify cropping)
    else:
        print("ERROR: unsupported dataset: ", args.dataset)
        exit(1)

    # Data
    print('==> Preparing data..')
    if args.augment:
        transform_train = transforms.Compose([
            transforms.RandomCrop(32, padding=4),
            transforms.RandomHorizontalFlip(),
            transforms.ToTensor(),
            normalize_transform,
        ])
    else:
        transform_train = transforms.Compose([
            transforms.ToTensor(),
            normalize_transform,
        ])

    transform_test = transforms.Compose([
        transforms.ToTensor(),
        normalize_transform,
    ])

    if args.dataset == 'cifar10':
        trainset = datasets.CIFAR10(root='~/data', train=True, download=True,
                                    transform=transform_train)
    elif args.dataset == 'cifar100':
        trainset = datasets.CIFAR100(root='~/data', train=True, download=True,
                                     transform=transform_train)
    elif args.dataset == 'mnist':
        trainset = datasets.MNIST(root='~/data', train=True, download=True,
                                  transform=transform_train)
    elif args.dataset == 'mnist_fashion':
        trainset = datasets.FashionMNIST(root='~/data', train=True, download=True,
                                         transform=transform_train)

    trainloader_a = torch.utils.data.DataLoader(trainset,
                                                batch_size=args.batch_size,
                                                shuffle=True, num_workers=8)

    trainloader_b = torch.utils.data.DataLoader(trainset,
                                                batch_size=args.batch_size,
                                                shuffle=True, num_workers=8)

    if args.dataset == 'cifar10':
        testset = datasets.CIFAR10(root='~/data', train=False, download=False,
                                   transform=transform_test)
    elif args.dataset == 'cifar100':
        testset = datasets.CIFAR100(root='~/data', train=False, download=False,
                                    transform=transform_test)

    testloader = torch.utils.data.DataLoader(testset, batch_size=100,
                                             shuffle=False, num_workers=8)

    # todo: only works for lebel_dim > num_classes; orthonormal_basis, _ = linalg.qr(x) may work for that case?
    orthonormal_basis = orth(np.random.rand(args.label_dim, num_classes))
    embeddings = torch.from_numpy(orthonormal_basis.transpose()).float()
    label_embedding = nn.Embedding(num_classes, args.label_dim).to(device)
    label_embedding.weight = nn.Parameter(embeddings.to(device))

    # Model
    print('==> Building model..')
    net = models.__dict__[args.model](num_classes, args.cosine_loss, args.label_dim)

    if use_cuda:
        net.cuda()
        net = torch.nn.DataParallel(net)
        print(torch.cuda.device_count())
        print('Using CUDA..')

    if args.cosine_loss:
        criterion = NegativeCosineLoss(args.label_dim)
        criterion_mixup = NegativeCosineLoss(args.label_dim)
    else:
        criterion = nn.CrossEntropyLoss()
        criterion_mixup = CrossEntropyLoss_SoftLabels(dim=1)

    optimizer = optim.SGD(net.parameters(), lr=args.lr, momentum=0.9,
                          weight_decay=args.decay)

    if args.checkpoint:
        # Load checkpoint.
        print('==> Resuming from checkpoint..')
        print(args.checkpoint)
        checkpoint = torch.load(args.checkpoint)
        net.load_state_dict(checkpoint['net_state_dicts'])
        optimizer.load_state_dict(checkpoint['optimizer_state_dict'])
        start_epoch = checkpoint['epoch'] + 1
        rng_state = checkpoint['rng_state']
        torch.set_rng_state(rng_state)

    def sample_lam_dat(batch_size):
        if args.stratified_sampling:
            # implemented as per Hull
            # if batch_size=5, cumulative_probabilities are random samples in the buckets
            # [0-0.2] [0.2-0.4] [0.4-0.6] [0.6-0.8] [0.8-1.0])
            cumulative_probabilities = np.linspace(0, 1, batch_size * 2 + 1)[0:-2:2]\
                                       + np.random.uniform(low=0, high=1 / batch_size, size=batch_size)
            lam_dat = beta.ppf(cumulative_probabilities, args.dat_parameters[0], args.dat_parameters[1])
        else:
            lam_dat = np.random.beta(args.dat_parameters[0], args.dat_parameters[1], size=batch_size)

        return lam_dat


    def mixup_lambda(batch_size):
        '''Returns lambda, gamma used for mixing inputs, labels in untied mixup'''

        # MUTUALLY EXCLUSIVE:
        # mixup: if true, both input and output are mixed
        # directional: if true, input but not output is mixed

        # ONLY IN COMBINATION WITH "mixup"
        # dat_transform: start with pDAT and get pMix + gamma

        if args.directional_adversarial:
            lam = sample_lam_dat(batch_size)
            gam = lam # gamma unused in directional adversarial, return dummy

        elif args.dat_transform:
            lam_dat = sample_lam_dat(batch_size)
            random_pick = np.random.choice(a=[False, True], size=batch_size)
            lam = np.where(random_pick, lam_dat, 1 - lam_dat)
            pdat_lam = beta.pdf(lam, args.dat_parameters[0], args.dat_parameters[1])
            pdat_lam_comp = beta.pdf(1 - lam, args.dat_parameters[0], args.dat_parameters[1])
            gam = pdat_lam / (pdat_lam + pdat_lam_comp)

        else:
            if args.stratified_sampling:
                cumulative_probabilities = np.linspace(0, 1, batch_size * 2 + 1)[0:-2:2]\
                                           + np.random.uniform(low=0, high=1 / batch_size, size=batch_size)
                lam = beta.ppf(cumulative_probabilities, args.lam_parameters[0], args.lam_parameters[1])
            else:
                lam = np.random.beta(args.lam_parameters[0], args.lam_parameters[1], size=batch_size)

            gam = beta.cdf(lam, args.gamma_parameters[0], args.gamma_parameters[1])

        lam = torch.from_numpy(lam).view(batch_size, 1, 1, 1).float().to(device)
        gam = torch.from_numpy(gam).view(batch_size, 1).float().to(device)

        return (lam, gam)

    def cosine_loss_predict(outputs, num_classes):
        normalized_prediction = F.normalize(outputs)
        true_labels = torch.from_numpy(np.arange(num_classes)).long().to(device)
        normalized_embedded_labels = label_embedding(true_labels)
        losses = -normalized_prediction @ torch.t(normalized_embedded_labels)
        _, predicted = torch.min(losses, 1)
        return predicted

    def train(epoch):
        print('\nEpoch: %d' % epoch)
        net.train()
        train_loss = 0
        reg_loss = 0
        correct = 0
        total = 0
        trainloader_b_iter = iter(trainloader_b)
        for batch_idx, (inputs_a, targets_a) in enumerate(trainloader_a):

            batch_size = inputs_a.size()[0]  # different than args.batch_size for last batch in epoch

            if args.iid_sampling:
                (inputs_b, targets_b) = next(trainloader_b_iter)
            else:
                index = torch.randperm(batch_size)
                inputs_b = inputs_a[index]
                targets_b = targets_a[index]

            inputs_a, targets_a = inputs_a.to(device), targets_a.to(device)
            inputs_b, targets_b = inputs_b.to(device), targets_b.to(device)

            if args.mixup or args.directional_adversarial:
                lam, gam = mixup_lambda(batch_size)
                inputs = lam * inputs_a + (1 - lam) * inputs_b
            else:
                inputs = inputs_a

            outputs = net(inputs)

            if args.mixup:
                if args.cosine_loss:
                    soft_labels_a = label_embedding(targets_a).to(device)
                    soft_labels_b = label_embedding(targets_b).to(device)
                else:
                    soft_labels_a = torch.eye(num_classes)[targets_a].to(device)
                    soft_labels_b = torch.eye(num_classes)[targets_b].to(device)

                soft_labels = gam * soft_labels_a + (1 - gam) * soft_labels_b
                loss = criterion_mixup(outputs, soft_labels)

            else:
                if args.cosine_loss:
                    soft_labels_a = label_embedding(targets_a).to(device)
                    loss = criterion_mixup(outputs, soft_labels_a)
                else:
                    loss = criterion(outputs, targets_a)
            train_loss += loss.data.item()

            if args.cosine_loss:
                predicted = cosine_loss_predict(outputs, num_classes)
            else:
                _, predicted = torch.max(outputs.data, 1)
            total += targets_a.size(0)
            if args.mixup:
                    correct += ((lam.squeeze() * predicted.eq(targets_a.data).float()).cpu().sum()
                                + ((1 - lam.squeeze()) * predicted.eq(targets_b.data).float()).cpu().sum())

            else:
                correct += predicted.eq(targets_a.data).cpu().sum()
            optimizer.zero_grad()
            loss.backward()
            optimizer.step()

        return (train_loss / batch_idx, reg_loss / batch_idx, 100. * correct.float() / total)

    def test(epoch):
        net.eval()
        test_loss = 0
        correct = 0
        total = 0
        for batch_idx, (inputs, targets) in enumerate(testloader):
            inputs, targets = inputs.to(device), targets.to(device)

            outputs = net(inputs)

            if args.cosine_loss:
                embedded_targets = label_embedding(targets).to(device)
                loss = criterion(outputs, embedded_targets)
                predicted = cosine_loss_predict(outputs, num_classes)

            else:
                loss = criterion(outputs, targets)
                _, predicted = torch.max(outputs.data, 1)

            test_loss += loss.data.item()
            total += targets.size(0)
            correct += predicted.eq(targets.data).cpu().sum()

        acc = 100. * correct.float() / total

        checkpoint_time_start = timeit.default_timer()
        checkpoint(epoch)
        checkpoint_time_end = timeit.default_timer()
        elapsed_seconds = round(checkpoint_time_end - checkpoint_time_start)
        print('Checkpoint Saving, Duration (Hours:Minutes:Seconds): ' + str(timedelta(seconds=elapsed_seconds)))
        return (test_loss / batch_idx, acc)


    def checkpoint(epoch):
        # Save checkpoint.
        print('Saving..')
        state = {
            'net_state_dicts': net.state_dict(),
            'optimizer_state_dict': optimizer.state_dict(),
            'epoch': epoch,
            'rng_state': torch.get_rng_state()
        }
        torch.save(state, ME_DIR + '/checkpoint_' + str(SEED) + '.torch')


    def adjust_learning_rate(optimizer, epoch):
        """decrease the learning rate at specific epochs"""
        lr = args.lr

        if args.decay_learning_rate:
            target_lr_phase1 = lr / 10
            target_lr_phase2 = target_lr_phase1 / 10
            gamma_phase1 = (target_lr_phase1 / args.lr) ** (1 / 101)
            gamma_phase2 = (target_lr_phase2 / target_lr_phase1) ** (1 / 50)
            if epoch <= 100:
                lr = lr * gamma_phase1 ** (epoch + 1)
            elif epoch <= 150:
                lr = target_lr_phase1 * gamma_phase2 ** (epoch - 100)
            else:
                lr = target_lr_phase2

        elif args.sanity_learning_rate:
            if epoch >= 100:
                lr /= 10
            if epoch >= 150:
                lr /= 10

        #else:
        #    if epoch >= 40:
        #        lr /= 10
        #    if epoch >= 100:
        #        lr /= 10
        #    # if epoch >= 200:
        #    #    lr /= 10

        for param_group in optimizer.param_groups:
            param_group['lr'] = lr


    for epoch in range(start_epoch, args.epoch):
        train_loss, reg_loss, train_acc = train(epoch)
        test_loss, test_acc = test(epoch)
        adjust_learning_rate(optimizer, epoch)
        print('Epoch: %d | Train Loss: %.6f | Train Acc: %.6f%% | Test Loss: %.6f | Test Acc: %.6f%% |'
              % (epoch, train_loss, train_acc, test_loss, test_acc))

    # Print elapsed time and current time
    elapsed_seconds = round(timeit.default_timer() - sim_time_start)
    print('Simulation Duration (Hours:Minutes:Seconds): ' + str(timedelta(seconds=elapsed_seconds)))
    print(datetime.datetime.now().strftime("END SIMULATION: %Y-%m-%d %H:%M"))