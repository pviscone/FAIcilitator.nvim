-- FAIcilitator.nvim entry guard. Nothing happens until the user calls
-- require("faicilitator").setup() from their own config.
if vim.g.loaded_faicilitator == 1 then
	return
end
vim.g.loaded_faicilitator = 1
