/**
 * List of supported options: https://github.com/defi-wonderland/natspec-smells?tab=readme-ov-file#options
 */

/** @type {import('@defi-wonderland/natspec-smells').Config} */
module.exports = {
  include: 'contracts/ecosystem/',
  include: 'contracts/upgrades/',
  include: 'contracts/interfaces/',
  include: 'contracts/markets/',
  exclude: 'contracts/vendor/**/',
  exclude: 'contracts/mock/**/',
  enforceInheritdoc: 'false'
};
