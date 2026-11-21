<?php
declare(strict_types=1);

namespace Cartunez\Storefront\Controller\Index;

use Cartunez\Storefront\Block\ProductRow;
use Magento\Framework\App\Action\HttpGetActionInterface;
use Magento\Framework\App\RequestInterface;
use Magento\Framework\View\Result\Page;
use Magento\Framework\View\Result\PageFactory;

/** A full page of best sellers, new arrivals or universal parts (layout parts_index_index.xml). */
class Index implements HttpGetActionInterface
{
    public function __construct(
        private readonly PageFactory $pageFactory,
        private readonly RequestInterface $request
    ) {
    }

    public function execute(): Page
    {
        $page = $this->pageFactory->create();
        $type = ProductRow::normalizeType((string)$this->request->getParam('list', ProductRow::TYPE_NEW));
        $page->getConfig()->getTitle()->set((string)ProductRow::title($type));
        return $page;
    }
}
