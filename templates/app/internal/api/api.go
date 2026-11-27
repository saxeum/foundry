package api

import "context"

// Handler implements the generated StrictServerInterface. Replacing this package
// with the app's real handlers is the first thing an app does; the generated
// contract and the /api prefix stay.
type Service struct{}

func New() *Service { return &Service{} }

func (s *Service) Hello(_ context.Context, _ HelloRequestObject) (HelloResponseObject, error) {
	return Hello200JSONResponse{Message: "hello from the foundry app template"}, nil
}
